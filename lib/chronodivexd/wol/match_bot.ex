defmodule Chronodivexd.Wol.MatchBot do
  @moduledoc """
  Unranked quick match for **1v1** and **random 2v2**. The client
  joins a quick-match channel (`#Lob 50 0` for 1v1,
  `#Lob 51 0` for 2v2) and whispers a virtual user "matchbot" with
  `ListQueues` / `Match …` / `Stats`, expecting whispered replies
  `QueueList …` / `Working` / `Matched <secs>` / `Stats <n>,<avgWait>`. The queue
  a `Match` belongs to is inferred from which `#Lob <id> 0` channel the sender is
  in (passed in by the Hub).

  When a queue has enough players (2 for 1v1, 4 for 2v2) we pair them: author a
  game-options string with team assignments (1v1 → teams 0/1; 2v2 → players
  0,1 = team 0, 2,3 = team 1), create a gserv instance server-side (neither
  client hosts — both `joinGame`, mapTransfer=false), and push `STARTG` to all.

  No map database, so options are built from a **template** captured from a real
  custom game with an official map (or `:quick_match_template`). Templates are
  tracked per minimum capacity: a 2-player map seeds 1v1; a 4+-player map seeds
  both. Ranked/ladder and the party (guaranteed-teammate) system are out of scope.
  """
  use GenServer
  require Logger

  alias Chronodivexd.Gserv.Registry
  alias Chronodivexd.Wol.GservUrl

  @bot_name "matchbot"
  @countdown 5

  # qm channel id → queue spec. size = players needed; type = LadderQueueType value.
  @queues %{50 => %{type: "1v1", size: 2}, 51 => %{type: "2v2", size: 4}}
  # Advertised order in QueueList replies.
  @queue_order ["1v1", "2v2"]

  @req_list_queues "ListQueues"
  @req_match "Match"
  @req_stats "Stats"
  @rpl_queue_list "QueueList"
  @rpl_working "Working"
  @rpl_mode_unavail "Unavailable"
  @rpl_matched "Matched"
  @rpl_stats "Stats"

  def bot_name, do: @bot_name

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "A whisper from `nick` (pid) to the matchbot; `queue_id` = the #Lob id they're in (or nil)."
  def message(pid, nick, text, queue_id, origin \\ %{}),
    do: GenServer.cast(__MODULE__, {:message, pid, nick, text, queue_id, origin})

  @doc "Player left (parted a qm channel or disconnected) — drop from all queues."
  def player_left(pid), do: GenServer.cast(__MODULE__, {:player_left, pid})

  @doc "Offer a custom game's options string as a quick-match map template."
  def maybe_set_template(opts), do: GenServer.cast(__MODULE__, {:maybe_set_template, opts})

  @impl true
  def init(_) do
    templates =
      case Application.get_env(:chronodivexd, :quick_match_template) do
        opts when is_binary(opts) -> apply_template(%{}, opts, ignore_official: true)
        _ -> %{}
      end

    map_pool = load_map_pool(Application.get_env(:chronodivexd, :quick_match_maps_file))

    {:ok, %{templates: templates, map_pool: map_pool, queues: %{"1v1" => [], "2v2" => []}}}
  end

  @impl true
  def handle_cast({:message, pid, nick, text, queue_id, origin}, st) do
    {:noreply, handle_message(String.trim(text), pid, nick, queue_id, origin, st)}
  end

  def handle_cast({:player_left, pid}, st) do
    queues = Map.new(st.queues, fn {t, q} -> {t, Enum.reject(q, &(&1.pid == pid))} end)
    {:noreply, %{st | queues: queues}}
  end

  def handle_cast({:maybe_set_template, opts}, st) do
    {:noreply, %{st | templates: apply_template(st.templates, opts, ignore_official: false)}}
  end

  @impl true
  def handle_info({:launch, game_id, ts, players}, st) do
    # Matched players must all reach the *same* gserv instance, so we advertise a
    # single URL — derived from one player's WOL origin (config GSERV_HOST still
    # overrides). Fine when they share a reachable host (same machine / LAN);
    # cross-network quick match needs an explicit public GSERV_HOST.
    origin = case players do
      [%{origin: o} | _] -> o
      _ -> %{}
    end

    line = ":#{srv()} STARTG qm:#{GservUrl.build(origin)} :#{game_id} #{ts}"
    for p <- players, do: send(p.pid, {:wol_out, line})
    Logger.info("MatchBot: launched #{game_id} for #{Enum.map_join(players, ", ", & &1.nick)}")
    {:noreply, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # ----- message handling -----

  defp handle_message(@req_list_queues, pid, nick, _queue_id, _origin, st) do
    available = Enum.filter(@queue_order, &available?(st, &1))
    whisper(pid, nick, "#{@rpl_queue_list} #{Enum.join(available, ",")}")
    st
  end

  defp handle_message(@req_stats, pid, nick, queue_id, _origin, st) do
    type = queue_type(queue_id)
    n = if type, do: length(Map.get(st.queues, type, [])), else: 0
    whisper(pid, nick, "#{@rpl_stats} #{n},-1")
    st
  end

  defp handle_message(@req_match <> " " <> rest, pid, nick, queue_id, origin, st),
    do: do_match(pid, nick, queue_id, rest, origin, st)

  defp handle_message(@req_match, pid, nick, queue_id, origin, st),
    do: do_match(pid, nick, queue_id, "", origin, st)

  defp handle_message(_other, _pid, _nick, _queue_id, _origin, st), do: st

  defp do_match(pid, nick, queue_id, tags, origin, st) do
    type = queue_type(queue_id)

    cond do
      type == nil or not available?(st, type) ->
        whisper(pid, nick, @rpl_mode_unavail)
        st

      already_queued?(st, pid) ->
        whisper(pid, nick, @rpl_working)
        st

      true ->
        whisper(pid, nick, @rpl_working)
        player = %{pid: pid, nick: nick, country: parse_country(tags), origin: origin}
        st = update_in(st.queues[type], &(&1 ++ [player]))
        maybe_pair(type, st)
    end
  end

  defp maybe_pair(type, st) do
    %{size: size} = Enum.find_value(@queues, fn {_id, q} -> q.type == type && q end)
    queue = Map.get(st.queues, type, [])

    if length(queue) >= size do
      {players, rest} = Enum.split(queue, size)
      map = pick_map(st, type)
      launch_match(type, players, base_template(st, type), map)
      %{st | queues: Map.put(st.queues, type, rest)}
    else
      st
    end
  end

  defp launch_match(type, players, template, map) do
    game_id = "qm-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    ts = System.system_time(:millisecond)
    opts = build_opts(type, players, template, map)
    if map, do: Logger.info("MatchBot: #{type} on map #{map.name}")

    case Registry.create(game_id, %{opts: opts}) do
      {:ok, _pid} ->
        for p <- players, do: whisper(p.pid, p.nick, "#{@rpl_matched} #{@countdown}")
        Process.send_after(self(), {:launch, game_id, ts, players}, @countdown * 1000)

      {:error, reason} ->
        Logger.error("MatchBot: failed to create instance #{game_id}: #{inspect(reason)}")
    end
  end

  # ----- options authoring -----

  # Reuse the template's meta (map + settings); replace humans with the matched
  # players. Random color/start (engine resolves deterministically from the shared
  # STARTG timestamp, so no collisions/desync); countries honored; teams per type.
  defp build_opts(type, players, template, map) do
    meta = template |> String.split(":") |> hd() |> swap_map(map)

    humans =
      players
      |> Enum.with_index()
      |> Enum.map_join(",", fn {p, i} ->
        "#{p.nick},#{p.country},-1,-1,#{team_for(type, i)},0,0,0"
      end)

    "#{meta}:#{humans}:@:,"
  end

  # Swap the chosen pool map into the template's meta: mapName (field 16),
  # optional maxSlots (13), and force mapOfficial (14). A standard filename is
  # used verbatim (a standard `name.ext` filename needs no encoding).
  defp swap_map(meta, nil), do: meta

  defp swap_map(meta, %{name: name} = map) do
    meta
    |> String.split(",")
    |> List.replace_at(16, name)
    |> List.replace_at(14, "1")
    |> replace_slots(map[:slots])
    |> Enum.join(",")
  end

  defp replace_slots(fields, slots) when is_integer(slots), do: List.replace_at(fields, 13, Integer.to_string(slots))
  defp replace_slots(fields, _), do: fields

  defp team_for("2v2", i), do: div(i, 2)
  defp team_for(_solo, i), do: i

  # ----- templates -----

  # Update the template map from an options string. A map with maxSlots >= 4 can
  # host 2v2 (and 1v1); >= 2 only 1v1. Only official maps are captured unless
  # ignore_official (used for the configured fallback).
  defp apply_template(templates, opts, ignore_official: ignore) do
    fields = opts |> String.split(":") |> hd() |> String.split(",")
    max_slots = fields |> Enum.at(13) |> to_int(0)
    official? = ignore or Enum.at(fields, 14) == "1"

    cond do
      not official? ->
        templates

      max_slots >= 4 ->
        Logger.info("MatchBot: captured quick-match template (1v1 + 2v2, #{max_slots} slots)")
        templates |> Map.put("1v1", opts) |> Map.put("2v2", opts)

      max_slots >= 2 ->
        Logger.info("MatchBot: captured quick-match template (1v1, #{max_slots} slots)")
        Map.put(templates, "1v1", opts)

      true ->
        templates
    end
  end

  # A queue is playable if we have a base options template AND either a captured
  # template for that exact queue or a configured map pool for it.
  defp available?(st, type) do
    base_template(st, type) != nil and
      (Map.has_key?(st.templates, type) or pool_for(st, type) != [])
  end

  # Base options come from the captured/configured template for this queue, or
  # any captured template (the map gets swapped from the pool anyway).
  defp base_template(st, type) do
    st.templates[type] || (st.templates |> Map.values() |> List.first())
  end

  defp pool_for(st, type), do: Map.get(st.map_pool, type, [])

  defp pick_map(st, type) do
    case pool_for(st, type) do
      [] -> nil
      maps -> Enum.random(maps)
    end
  end

  # Parse a bnmaps-style file into %{"1v1" => [%{name, slots}], "2v2" => [...]}.
  defp load_map_pool(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        pool =
          contents
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Enum.reduce(%{"1v1" => [], "2v2" => []}, fn line, acc ->
            case String.split(line, ~r/\s+/) do
              [queue, name | rest] when queue in ["1v1", "2v2"] ->
                entry = %{name: name, slots: parse_slots(rest)}
                Map.update(acc, queue, [entry], &(&1 ++ [entry]))

              _ ->
                acc
            end
          end)

        total = Enum.sum(Enum.map(pool, fn {_t, l} -> length(l) end))
        Logger.info("MatchBot: loaded #{total} quick-match maps from #{path}")
        pool

      {:error, reason} ->
        Logger.warning("MatchBot: couldn't read map pool #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp load_map_pool(_), do: %{}

  defp parse_slots([s | _]) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_slots(_), do: nil

  defp queue_type(nil), do: nil
  defp queue_type(id), do: get_in(@queues, [id, :type])

  defp already_queued?(st, pid) do
    Enum.any?(st.queues, fn {_t, q} -> Enum.any?(q, &(&1.pid == pid)) end)
  end

  defp parse_country(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value("-1", fn tag ->
      case String.split(tag, "=", parts: 2) do
        ["COU", v] -> v
        _ -> nil
      end
    end)
  end

  defp to_int(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp whisper(pid, to_nick, text) do
    send(pid, {:wol_out, ":#{@bot_name}!u@h PRIVMSG #{to_nick} :#{text}"})
  end

  defp srv, do: Application.fetch_env!(:chronodivexd, :server_name)
end
