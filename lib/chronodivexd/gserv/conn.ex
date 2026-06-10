defmodule Chronodivexd.Gserv.Conn do
  @moduledoc """
  WebSock handler for a single gserv (in-game) connection. Parses the text
  commands and binary frames the client sends
  and drives the match's `Chronodivexd.Gserv.Instance`. Text frames carry commands;
  binary frames (`<<0x02, code, …>>`) carry map transfer / lockstep actions /
  state hashes.
  """
  @behaviour WebSock
  require Logger

  alias Chronodivexd.Accounts
  alias Chronodivexd.Gserv.{Codes, Instance, Registry}

  defmodule State do
    @moduledoc false
    defstruct name: nil, instance: nil, game_id: nil
  end

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_in({data, [opcode: :text]}, state) do
    state =
      data
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(state, &dispatch_text/2)

    {:ok, state}
  end

  def handle_in({data, [opcode: :binary]}, state) do
    {:ok, dispatch_bin(data, state)}
  end

  @impl true
  def handle_info({:gserv_out, {:text, line}}, state), do: {:push, {:text, line <> "\r\n"}, state}
  def handle_info({:gserv_out, {:binary, bin}}, state), do: {:push, {:binary, bin}, state}
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # ----- text commands -----

  defp dispatch_text(line, state) do
    {cmd, rest} = split_cmd(line)

    case String.downcase(cmd) do
      "cvers" ->
        reply(":#{srv()} #{Codes.rpl_cvers_ok()} x :ok")
        state

      "user" ->
        handle_user(rest, state)

      "create" ->
        handle_create(rest, state)

      "join" ->
        handle_join(rest, state)

      "gameopts" ->
        if state.instance, do: reply(":#{srv()} #{Codes.rpl_game_opts()} x :#{Instance.opts(state.instance)}")
        state

      "loaded" ->
        with_instance(state, fn pid -> Instance.set_loaded(pid, self(), parse_int(rest, 0)) end)

      "loadinfo" ->
        with_instance(state, fn pid -> Instance.loadinfo(pid, self()) end)

      "active" ->
        with_instance(state, fn pid -> Instance.set_active(pid, self(), String.trim(rest) == "1") end)

      "taunt" ->
        with_instance(state, fn pid -> Instance.taunt(pid, self(), parse_int(rest, 0)) end)

      "privmsg" ->
        handle_privmsg(rest, state)

      "ping" ->
        reply(":#{srv()} PONG #{srv()} :#{strip_colon(String.trim(rest))}")
        state

      "pong" ->
        state

      _ ->
        Logger.debug("gserv: ignoring unknown command #{inspect(line)}")
        state
    end
  end

  defp handle_user(rest, state) do
    case String.split(rest, " ", trim: true) do
      [name, b64 | _] ->
        case Accounts.verify(name, decode_pass(b64)) do
          {:ok, nick} ->
            reply(":#{srv()} #{Codes.rpl_logged_in()} x :ok")
            %{state | name: nick}

          :error ->
            reply(":#{srv()} #{Codes.rpl_bad_login()} x :Invalid login")
            state
        end

      _ ->
        reply(":#{srv()} #{Codes.rpl_bad_login()} x :Invalid login")
        state
    end
  end

  # create <gameId> <ts> <opts> <ver> <modHash> <private>
  defp handle_create(rest, %State{name: name} = state) when is_binary(name) do
    case String.split(rest, " ", trim: true) do
      [game_id, _ts, opts | _] ->
        case Registry.create(game_id, %{}) do
          {:ok, pid} ->
            case Instance.attach_host(pid, self(), name, opts) do
              :ok ->
                # Offer this custom game's options as the quick-match map template.
                Chronodivexd.Wol.MatchBot.maybe_set_template(opts)
                reply(":#{srv()} #{Codes.rpl_instance_created()} x :ok")
                %{state | instance: pid, game_id: game_id}

              {:error, _} ->
                reply(":#{srv()} #{Codes.rpl_instance_not_allowed()} x :not allowed")
                state
            end

          {:error, :exists} ->
            reply(":#{srv()} #{Codes.rpl_instance_exists()} x :exists")
            state
        end

      _ ->
        state
    end
  end

  defp handle_create(_rest, state), do: state

  # join <gameId> <ver> <modHash>
  defp handle_join(rest, %State{name: name} = state) when is_binary(name) do
    case String.split(rest, " ", trim: true) do
      [game_id | _] ->
        case Registry.lookup(game_id) do
          {:ok, pid} ->
            case Instance.attach_join(pid, self(), name) do
              :ok ->
                reply(":#{srv()} #{Codes.rpl_instance_connected()} x :ok")
                %{state | instance: pid, game_id: game_id}

              {:error, :already_started} ->
                reply(":#{srv()} #{Codes.rpl_instance_already_started()} x :started")
                state

              {:error, _} ->
                reply(":#{srv()} #{Codes.rpl_instance_not_allowed()} x :not allowed")
                state
            end

          :error ->
            # Not created yet; client retries.
            reply(":#{srv()} #{Codes.rpl_instance_nonexistent()} x :no such instance")
            state
        end

      _ ->
        state
    end
  end

  defp handle_join(_rest, state), do: state

  defp handle_privmsg(rest, state) do
    with_instance(state, fn pid ->
      {targets, text} = split_target_and_text(rest)
      Instance.privmsg(pid, self(), String.split(targets, ","), text)
    end)
  end

  # ----- binary frames -----

  defp dispatch_bin(data, %State{instance: pid} = state) when is_pid(pid) do
    prefix = Codes.req_bin_prefix()

    case data do
      <<^prefix, 1, turn::little-32, payload::binary>> ->
        Instance.actions(pid, self(), turn, payload)

      <<^prefix, 2, turn::little-32, hash::little-32>> ->
        Instance.state_hash(pid, self(), turn, hash)

      <<^prefix, 3, map::binary>> ->
        Instance.put_map(pid, map)

      <<^prefix, 4>> ->
        Instance.get_map(pid, self())

      _ ->
        Logger.debug("gserv: unhandled binary frame")
    end

    state
  end

  defp dispatch_bin(_data, state), do: state

  # ----- helpers -----

  defp with_instance(%State{instance: pid} = state, fun) when is_pid(pid) do
    fun.(pid)
    state
  end

  defp with_instance(state, _fun), do: state

  defp split_cmd(line) do
    case String.split(line, " ", parts: 2) do
      [cmd, rest] -> {cmd, rest}
      [cmd] -> {cmd, ""}
    end
  end

  defp split_target_and_text(rest) do
    case String.split(rest, " :", parts: 2) do
      [target, text] -> {String.trim(target), text}
      [target] -> {String.trim(target), ""}
    end
  end

  defp strip_colon(":" <> rest), do: rest
  defp strip_colon(s), do: s

  defp decode_pass(b64) do
    case Base.decode64(b64) do
      {:ok, p} -> p
      :error -> ""
    end
  end

  defp parse_int(s, default) do
    case s |> String.trim() |> Integer.parse() do
      {n, _} -> n
      :error -> default
    end
  end

  defp reply(line), do: send(self(), {:gserv_out, {:text, line}})
  defp srv, do: Application.fetch_env!(:chronodivexd, :server_name)
end
