defmodule Chronodivexd.Gserv.Instance do
  @moduledoc """
  One running match. Holds the game-options string, the host-transferred map,
  per-connection player state, and the lockstep turn buffers. Drives the start
  gate (all players loaded → NET_RATE + GAME_START) and the per-turn binary
  action relay.

  Outbound frames are delivered to connection pids as
  `{:gserv_out, {:text, line}}` / `{:gserv_out, {:binary, bytes}}`.
  """
  use GenServer
  require Logger

  alias Chronodivexd.Gserv.{Codes, Opts}

  # Network turn length handed to clients (ms). The client turns this into a
  # whole number of game ticks; any positive value
  # is correct, this one only affects feel/latency.
  @net_rate_ms 200

  def start_link(game_id, opts), do: GenServer.start_link(__MODULE__, {game_id, opts})

  # host attaches with the opts string; joiners attach without.
  def attach_host(pid, conn, name, opts_str),
    do: GenServer.call(pid, {:attach, conn, name, :host, opts_str})

  def attach_join(pid, conn, name), do: GenServer.call(pid, {:attach, conn, name, :join, nil})

  def opts(pid), do: GenServer.call(pid, :opts)

  def set_loaded(pid, conn, pct), do: GenServer.cast(pid, {:set_loaded, conn, pct})
  def loadinfo(pid, conn), do: GenServer.cast(pid, {:loadinfo, conn})
  def set_active(pid, conn, active?), do: GenServer.cast(pid, {:set_active, conn, active?})
  def actions(pid, conn, turn, payload), do: GenServer.cast(pid, {:actions, conn, turn, payload})
  def state_hash(pid, conn, turn, hash), do: GenServer.cast(pid, {:state_hash, conn, turn, hash})
  def put_map(pid, bytes), do: GenServer.cast(pid, {:put_map, bytes})
  def get_map(pid, conn), do: GenServer.cast(pid, {:get_map, conn})
  def taunt(pid, conn, n), do: GenServer.cast(pid, {:taunt, conn, n})
  def privmsg(pid, conn, targets, text), do: GenServer.cast(pid, {:privmsg, conn, targets, text})

  # ----- GenServer -----

  @impl true
  def init({game_id, opts}) do
    st = %{
      game_id: game_id,
      opts: nil,
      player_ids: %{},
      expected: MapSet.new(),
      map: nil,
      pending_map: [],
      # conn_pid => %{name, player_id, loaded, active}
      conns: %{},
      started: false,
      turns: %{},
      next_relay_turn: 0,
      hashes: %{}
    }

    # Quick-match instances are created server-side with the options string
    # already known (no client hosts). Custom games leave this nil and the host
    # sets it via attach_host.
    st =
      case opts do
        %{opts: o} when is_binary(o) -> set_opts(st, o)
        _ -> st
      end

    {:ok, st}
  end

  defp set_opts(st, opts_str) do
    ids = Opts.player_ids(opts_str)
    %{st | opts: opts_str, player_ids: ids, expected: MapSet.new(Map.values(ids))}
  end

  @impl true
  def handle_call({:attach, conn, name, role, opts_str}, _from, st) do
    st = if role == :host and st.opts == nil, do: set_opts(st, opts_str), else: st

    cond do
      role == :join and st.started ->
        {:reply, {:error, :already_started}, st}

      true ->
        case Map.get(st.player_ids, String.downcase(name)) do
          nil ->
            {:reply, {:error, :not_allowed}, st}

          player_id ->
            Process.monitor(conn)
            conn_state = %{name: name, player_id: player_id, loaded: 0, active: true}
            st = put_in(st.conns[conn], conn_state)
            Logger.info("gserv #{st.game_id}: #{name} attached as player #{player_id} (#{role})")
            {:reply, :ok, st}
        end
    end
  end

  def handle_call(:opts, _from, st), do: {:reply, st.opts || "", st}

  @impl true
  def handle_cast({:set_loaded, conn, pct}, st) do
    st = update_conn(st, conn, &Map.put(&1, :loaded, pct))
    broadcast_loadinfo(st)
    {:noreply, maybe_start(st)}
  end

  def handle_cast({:loadinfo, _conn}, st) do
    broadcast_loadinfo(st)
    {:noreply, st}
  end

  def handle_cast({:set_active, conn, active?}, st) do
    st = update_conn(st, conn, &Map.put(&1, :active, active?))
    {:noreply, relay_ready_turns(st)}
  end

  def handle_cast({:actions, conn, turn, payload}, st) do
    case Map.get(st.conns, conn) do
      %{player_id: pid} ->
        turns = Map.update(st.turns, turn, %{pid => payload}, &Map.put(&1, pid, payload))
        {:noreply, relay_ready_turns(%{st | turns: turns})}

      _ ->
        {:noreply, st}
    end
  end

  def handle_cast({:state_hash, conn, turn, hash}, st) do
    case Map.get(st.conns, conn) do
      %{name: name} ->
        case Map.get(st.hashes, turn) do
          nil ->
            {:noreply, put_in(st.hashes[turn], hash)}

          ^hash ->
            {:noreply, st}

          _other ->
            Logger.warning("gserv #{st.game_id}: DESYNC at turn #{turn} reported by #{name}")
            broadcast(st, {:text, ":#{srv()} #{Codes.rpl_game_desync()} x :desync"})
            {:noreply, st}
        end

      _ ->
        {:noreply, st}
    end
  end

  def handle_cast({:put_map, bytes}, st) do
    frame = {:binary, <<Codes.rpl_bin_prefix(), Codes.rpl_bin_map_data(), bytes::binary>>}
    for conn <- st.pending_map, do: send(conn, {:gserv_out, frame})
    Logger.info("gserv #{st.game_id}: host uploaded map (#{byte_size(bytes)} bytes)")
    {:noreply, %{st | map: bytes, pending_map: []}}
  end

  def handle_cast({:get_map, conn}, st) do
    case st.map do
      nil ->
        {:noreply, %{st | pending_map: [conn | st.pending_map]}}

      bytes ->
        send(conn, {:gserv_out, {:binary, <<Codes.rpl_bin_prefix(), Codes.rpl_bin_map_data(), bytes::binary>>}})
        {:noreply, st}
    end
  end

  def handle_cast({:taunt, conn, n}, st) do
    case Map.get(st.conns, conn) do
      %{name: name} -> broadcast(st, {:text, ":#{name} #{Codes.rpl_taunt()} #all :#{n}"})
      _ -> :ok
    end

    {:noreply, st}
  end

  def handle_cast({:privmsg, conn, targets, text}, st) do
    case Map.get(st.conns, conn) do
      %{name: from} ->
        for target <- targets do
          line = ":#{from} PRIVMSG #{target} :#{text}"

          if target == "#all" do
            broadcast(st, {:text, line})
          else
            deliver_to_name(st, target, {:text, line})
          end
        end

      _ ->
        :ok
    end

    {:noreply, st}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, conn, _reason}, st) do
    case Map.get(st.conns, conn) do
      nil ->
        {:noreply, st}

      %{name: name} ->
        st = %{st | conns: Map.delete(st.conns, conn)}
        broadcast(st, {:text, ":#{srv()} #{Codes.rpl_player_disconnect()} x :#{name}"})
        Logger.info("gserv #{st.game_id}: #{name} disconnected")

        if map_size(st.conns) == 0 do
          {:stop, :normal, st}
        else
          {:noreply, relay_ready_turns(st)}
        end
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # ----- start gate -----

  defp maybe_start(%{started: true} = st), do: st

  defp maybe_start(st) do
    loaded_ids =
      st.conns
      |> Map.values()
      |> Enum.filter(&(&1.loaded >= 100))
      |> Enum.map(& &1.player_id)
      |> MapSet.new()

    if MapSet.size(st.expected) > 0 and MapSet.subset?(st.expected, loaded_ids) do
      Logger.info("gserv #{st.game_id}: all players loaded — starting")
      broadcast(st, {:text, ":#{srv()} #{Codes.rpl_net_rate()} x :#{@net_rate_ms},0"})
      broadcast(st, {:text, ":#{srv()} #{Codes.rpl_game_start()}"})
      %{st | started: true}
    else
      st
    end
  end

  # ----- lockstep relay -----

  # Broadcast consecutive fully-submitted turns starting at next_relay_turn.
  defp relay_ready_turns(st) do
    required = active_player_ids(st)
    turn = st.next_relay_turn
    submitted = st.turns |> Map.get(turn, %{}) |> Map.keys() |> MapSet.new()

    if MapSet.size(required) > 0 and MapSet.subset?(required, submitted) do
      frame = build_actions_frame(turn, Map.get(st.turns, turn))
      broadcast(st, {:binary, frame})
      st = %{st | turns: Map.delete(st.turns, turn), next_relay_turn: turn + 1}
      relay_ready_turns(st)
    else
      st
    end
  end

  defp active_player_ids(st) do
    st.conns
    |> Map.values()
    |> Enum.filter(& &1.active)
    |> Enum.map(& &1.player_id)
    |> MapSet.new()
  end

  # <<prefix, code, turn::32le, count, (player_id, len::16le, payload)...>>
  defp build_actions_frame(turn, by_player) do
    body =
      for {player_id, payload} <- by_player, into: <<>> do
        <<player_id::8, byte_size(payload)::little-16, payload::binary>>
      end

    <<Codes.rpl_bin_prefix(), Codes.rpl_bin_game_actions(), turn::little-32, map_size(by_player)::8,
      body::binary>>
  end

  # ----- helpers -----

  defp broadcast_loadinfo(st) do
    body =
      st.conns
      |> Map.values()
      |> Enum.map_join(",", fn c -> "#{c.name},1,#{c.loaded},0,0" end)

    if body != "", do: broadcast(st, {:text, ":#{srv()} #{Codes.rpl_load_info()} x :#{body}"})
  end

  defp broadcast(st, frame) do
    for {conn, _} <- st.conns, do: send(conn, {:gserv_out, frame})
    :ok
  end

  defp deliver_to_name(st, name, frame) do
    key = String.downcase(name)

    Enum.each(st.conns, fn {conn, c} ->
      if String.downcase(c.name) == key, do: send(conn, {:gserv_out, frame})
    end)
  end

  defp update_conn(st, conn, fun) do
    case Map.get(st.conns, conn) do
      nil -> st
      c -> put_in(st.conns[conn], fun.(c))
    end
  end

  defp srv, do: Application.fetch_env!(:chronodivexd, :server_name)
end
