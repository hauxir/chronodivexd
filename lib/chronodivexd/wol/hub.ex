defmodule Chronodivexd.Wol.Hub do
  @moduledoc """
  The shared WOL lobby world: online sessions, channels (membership / ops /
  password / `+l` limit / topic) and the registry of game rooms used to answer
  `list`. One GenServer; connection processes (`Chronodivexd.Wol.Conn`) call in and
  receive outbound IRC lines as `{:wol_out, line}` messages to their pid.

  Channel names are stored **unescaped** (canonical); they're escaped only on
  the wire.
  """
  use GenServer
  require Logger

  alias Chronodivexd.Irc
  alias Chronodivexd.Wol.Codes

  @op_prefix "@"
  # `passFlag` value the client treats as "password locked".
  @pass_locked_flag 384

  # ----- client-facing API (called from Conn) -----

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def login(nick, pid, fresh?), do: GenServer.call(__MODULE__, {:login, nick, pid, fresh?})
  def disconnect(pid), do: GenServer.cast(__MODULE__, {:disconnect, pid})
  def set_ping(pid, ping), do: GenServer.cast(__MODULE__, {:set_ping, pid, ping})

  def join_channel(pid, chan, key), do: GenServer.call(__MODULE__, {:join_channel, pid, chan, key})
  def part_channel(pid, chan), do: GenServer.call(__MODULE__, {:part_channel, pid, chan})
  def names(pid, chan), do: GenServer.call(__MODULE__, {:names, pid, chan})
  def list_games(pid), do: GenServer.call(__MODULE__, {:list_games, pid})

  def create_game(pid, chan, meta), do: GenServer.call(__MODULE__, {:create_game, pid, chan, meta})

  def join_game(pid, chan, observer?, key),
    do: GenServer.call(__MODULE__, {:join_game, pid, chan, observer?, key})

  def gameopt(pid, chan, opt), do: GenServer.call(__MODULE__, {:gameopt, pid, chan, opt})
  def set_topic(pid, chan, topic), do: GenServer.call(__MODULE__, {:set_topic, pid, chan, topic})
  def set_mode_limit(pid, chan, n), do: GenServer.call(__MODULE__, {:set_mode_limit, pid, chan, n})
  def kick(pid, chan, targets, reason), do: GenServer.call(__MODULE__, {:kick, pid, chan, targets, reason})

  def privmsg(pid, targets, text), do: GenServer.call(__MODULE__, {:privmsg, pid, targets, text})
  def page(pid, target, text, verb), do: GenServer.call(__MODULE__, {:page, pid, target, text, verb})
  def start_game(pid, chan, players), do: GenServer.call(__MODULE__, {:start_game, pid, chan, players})

  # ----- GenServer -----

  @impl true
  def init(_) do
    {:ok,
     %{
       # nick(downcased) => %{nick: display, pid: pid, ping: int, fresh: bool}
       sessions: %{},
       # pid => nick(downcased)
       pids: %{},
       # chan(unescaped) => channel map
       channels: %{}
     }}
  end

  @impl true
  def handle_call({:login, nick, pid, fresh?}, _from, st) do
    key = String.downcase(nick)

    st =
      case Map.get(st.sessions, key) do
        %{pid: old} when old != pid ->
          send(old, :replaced)
          remove_pid(st, old)

        _ ->
          st
      end

    Process.monitor(pid)
    session = %{nick: nick, pid: pid, ping: 0, fresh: fresh?}
    st = %{st | sessions: Map.put(st.sessions, key, session), pids: Map.put(st.pids, pid, key)}
    {:reply, :ok, st}
  end

  def handle_call({:join_channel, pid, chan, key}, _from, st) do
    with {:ok, sess} <- session(st, pid) do
      case Map.get(st.channels, chan) do
        nil ->
          ch = new_channel(chan, :lobby, key) |> add_member(sess, false)
          st = put_in(st.channels[chan], ch)
          announce_join(ch, sess, :join, false)
          {:reply, :ok, st}

        %{kind: :game} ->
          err(pid, sess.nick, Codes.err_nosuchchannel(), Irc.escape(chan), "Not a chat channel")
          {:reply, {:error, :nosuchchannel}, st}

        ch ->
          cond do
            ch.key && ch.key != key ->
              err(pid, sess.nick, Codes.err_badchannelkey(), Irc.escape(chan), "Bad channel key")
              {:reply, {:error, :badkey}, st}

            full?(ch) ->
              err(pid, sess.nick, Codes.err_channelisfull(), Irc.escape(chan), "Channel is full")
              {:reply, {:error, :full}, st}

            true ->
              ch = add_member(ch, sess, false)
              st = put_in(st.channels[chan], ch)
              announce_join(ch, sess, :join, false)
              {:reply, :ok, st}
          end
      end
    else
      _ -> {:reply, {:error, :not_logged_in}, st}
    end
  end

  def handle_call({:part_channel, pid, chan}, _from, st) do
    with {:ok, sess} <- session(st, pid),
         %{} = ch <- Map.get(st.channels, chan),
         true <- member?(ch, sess.nick) do
      broadcast(ch, part_line(sess.nick, chan))
      Chronodivexd.Wol.MatchBot.player_left(pid)
      {:reply, :ok, drop_member(st, chan, sess.nick)}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:names, pid, chan}, _from, st) do
    with {:ok, sess} <- session(st, pid), %{} = ch <- Map.get(st.channels, chan) do
      send_names(pid, sess.nick, ch)
      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:list_games, pid}, _from, st) do
    with {:ok, sess} <- session(st, pid) do
      push(pid, ":#{srv()} #{Codes.rpl_liststart()} #{sess.nick} :Channel Users Name")

      for {_name, ch} <- st.channels, ch.kind == :game, is_binary(ch.topic) do
        push(pid, game_list_line(sess.nick, ch))
      end

      push(pid, ":#{srv()} #{Codes.rpl_listend()} #{sess.nick} :End of /LIST")
      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:create_game, pid, chan, meta}, _from, st) do
    with {:ok, sess} <- session(st, pid) do
      if Map.has_key?(st.channels, chan) do
        err(pid, sess.nick, Codes.err_channelisfull(), Irc.escape(chan), "Game already exists")
        {:reply, {:error, :exists}, st}
      else
        ch =
          new_channel(chan, :game, meta.pass)
          |> Map.merge(%{
            tournament: meta.tournament,
            res_locked: meta.res_locked,
            type: meta.type,
            host: sess.nick
          })
          |> add_member(sess, true)

        st = put_in(st.channels[chan], ch)
        push(pid, joingame_line(sess.nick, chan, sess.ping, sess.fresh))
        send_names(pid, sess.nick, ch)
        Logger.info("#{sess.nick} created game #{inspect(chan)}")
        {:reply, :ok, st}
      end
    else
      _ -> {:reply, {:error, :not_logged_in}, st}
    end
  end

  def handle_call({:join_game, pid, chan, observer?, key}, _from, st) do
    with {:ok, sess} <- session(st, pid) do
      case Map.get(st.channels, chan) do
        %{kind: :game} = ch ->
          cond do
            ch.key && ch.key != key ->
              err(pid, sess.nick, Codes.err_badchannelkey(), Irc.escape(chan), "Bad channel key")
              {:reply, {:error, :badkey}, st}

            full?(ch) and not observer? ->
              err(pid, sess.nick, Codes.err_channelisfull(), Irc.escape(chan), "Channel is full")
              {:reply, {:error, :full}, st}

            true ->
              ch = add_member(ch, sess, false)
              st = put_in(st.channels[chan], ch)
              line = joingame_line(sess.nick, chan, sess.ping, sess.fresh)
              broadcast(ch, line, except: pid)
              push(pid, line)
              send_names(pid, sess.nick, ch)
              {:reply, :ok, st}
          end

        _ ->
          err(pid, sess.nick, Codes.err_gamehasclosed(), Irc.escape(chan), "Game has closed")
          {:reply, {:error, :closed}, st}
      end
    else
      _ -> {:reply, {:error, :not_logged_in}, st}
    end
  end

  def handle_call({:gameopt, pid, chan, opt}, _from, st) do
    relay(st, pid, chan, fn nick -> ":#{userhost(nick)} GAMEOPT #{Irc.escape(chan)} :#{opt}" end)
  end

  def handle_call({:set_topic, pid, chan, topic}, _from, st) do
    with {:ok, sess} <- session(st, pid),
         %{} = ch <- Map.get(st.channels, chan),
         true <- member?(ch, sess.nick) do
      {:reply, :ok, put_in(st.channels[chan].topic, topic)}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:set_mode_limit, pid, chan, n}, _from, st) do
    with {:ok, sess} <- session(st, pid),
         %{} = ch <- Map.get(st.channels, chan),
         true <- member?(ch, sess.nick) do
      st = put_in(st.channels[chan].limit, n)
      line = ":#{userhost(sess.nick)} MODE #{Irc.escape(chan)} +l #{n}"
      broadcast(Map.get(st.channels, chan), line, except: pid)
      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:kick, pid, chan, targets, reason}, _from, st) do
    with {:ok, sess} <- session(st, pid),
         %{} = ch <- Map.get(st.channels, chan),
         true <- operator?(ch, sess.nick) do
      st =
        Enum.reduce(targets, st, fn target, st ->
          ch = Map.get(st.channels, chan)

          if ch && member?(ch, target) do
            broadcast(ch, ":#{userhost(sess.nick)} KICK #{Irc.escape(chan)} #{target} :#{reason}")
            drop_member(st, chan, target)
          else
            st
          end
        end)

      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:privmsg, pid, targets, text}, _from, st) do
    with {:ok, sess} <- session(st, pid) do
      for target <- targets do
        cond do
          String.starts_with?(target, "#") ->
            chan = Irc.unescape(target)

            case Map.get(st.channels, chan) do
              %{} = ch -> broadcast(ch, ":#{userhost(sess.nick)} PRIVMSG #{Irc.escape(chan)} :#{text}", except: pid)
              _ -> :ok
            end

          # Quick-match: whispers to the virtual "matchbot" drive matchmaking.
          # The queue is inferred from which `#Lob <id> 0` channel they're in.
          String.downcase(target) == Chronodivexd.Wol.MatchBot.bot_name() ->
            Chronodivexd.Wol.MatchBot.message(pid, sess.nick, text, qm_channel_id(st, sess.nick))

          true ->
            deliver_to_nick(st, target, ":#{userhost(sess.nick)} PRIVMSG #{target} :#{text}")
        end
      end

      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:page, pid, target, text, verb}, _from, st) do
    with {:ok, sess} <- session(st, pid) do
      deliver_to_nick(st, target, ":#{userhost(sess.nick)} #{verb} #{target} :#{text}")
      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:start_game, pid, chan, _players}, _from, st) do
    with {:ok, sess} <- session(st, pid),
         %{kind: :game} = ch <- Map.get(st.channels, chan),
         true <- operator?(ch, sess.nick) do
      game_id = gen_game_id()
      ts = System.system_time(:millisecond)
      scheme = Application.fetch_env!(:chronodivexd, :gserv_scheme)
      gserv_url = "#{scheme}://#{Application.fetch_env!(:chronodivexd, :gserv_host)}/gserv"
      broadcast(ch, ":#{srv()} STARTG #{Irc.escape(chan)}:#{gserv_url} :#{game_id} #{ts}")
      Logger.info("Starting game #{inspect(chan)} as instance #{game_id}")
      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  @impl true
  def handle_cast({:disconnect, pid}, st), do: {:noreply, remove_pid(st, pid)}

  def handle_cast({:set_ping, pid, ping}, st) do
    case Map.get(st.pids, pid) do
      nil -> {:noreply, st}
      key -> {:noreply, update_in(st.sessions[key], &Map.put(&1, :ping, ping))}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st), do: {:noreply, remove_pid(st, pid)}
  def handle_info(_msg, st), do: {:noreply, st}

  # ----- internal helpers -----

  defp session(st, pid) do
    with key when is_binary(key) <- Map.get(st.pids, pid),
         %{} = sess <- Map.get(st.sessions, key) do
      {:ok, sess}
    else
      _ -> :error
    end
  end

  defp new_channel(name, kind, key) do
    %{
      name: name,
      kind: kind,
      key: blank_to_nil(key),
      limit: nil,
      topic: nil,
      tournament: false,
      res_locked: false,
      type: nil,
      host: nil,
      # member nick(downcased) => %{nick: display, op: bool, pid: pid}
      members: %{}
    }
  end

  defp add_member(ch, sess, op) do
    put_in(ch.members[String.downcase(sess.nick)], %{nick: sess.nick, op: op, pid: sess.pid})
  end

  defp member?(ch, nick), do: Map.has_key?(ch.members, String.downcase(nick))
  defp operator?(ch, nick), do: get_in(ch.members, [String.downcase(nick), :op]) == true

  defp full?(%{limit: nil}), do: false
  defp full?(%{limit: limit, members: m}), do: map_size(m) >= limit

  defp drop_member(st, chan, nick) do
    case Map.get(st.channels, chan) do
      nil ->
        st

      ch ->
        members = Map.delete(ch.members, String.downcase(nick))

        if map_size(members) == 0 do
          %{st | channels: Map.delete(st.channels, chan)}
        else
          put_in(st.channels[chan].members, members)
        end
    end
  end

  # JOIN/JOINGAME announce: broadcast to existing members, echo to joiner, NAMES.
  defp announce_join(ch, sess, :join, op) do
    line = join_line(sess.nick, ch.name, sess.ping, op, sess.fresh)
    broadcast(ch, line, except: sess.pid)
    push(sess.pid, line)
    send_names(sess.pid, sess.nick, ch)
  end

  defp send_names(pid, nick, ch) do
    tokens =
      ch.members
      |> Map.values()
      |> Enum.sort_by(fn m -> {if(m.op, do: 0, else: 1), String.downcase(m.nick)} end)
      |> Enum.map_join(" ", fn m ->
        prefix = if m.op, do: @op_prefix, else: ""
        "#{prefix}#{m.nick},0,0,0"
      end)

    push(pid, ":#{srv()} #{Codes.rpl_namreply()} #{nick} = #{Irc.escape(ch.name)} :#{tokens}")
    push(pid, ":#{srv()} #{Codes.rpl_endofnames()} #{nick} #{Irc.escape(ch.name)} :End of /NAMES list")
  end

  defp game_list_line(nick, ch) do
    humans = map_size(ch.members)
    host_ping = 0
    pass_flag = if ch.key, do: @pass_locked_flag, else: 0
    tourney = if ch.tournament, do: 1, else: 0
    res_locked = if ch.res_locked, do: 1, else: 0
    type = ch.type || 45

    ":#{srv()} #{Codes.rpl_game_channel()} #{nick} #{Irc.escape(ch.name)} #{humans} 0 #{type} " <>
      "#{tourney} #{res_locked} #{host_ping} #{pass_flag}::#{ch.topic} 0"
  end

  # JOIN echo metadata token = flags,ping,operator,fresh.
  defp join_line(nick, chan, ping, op, fresh) do
    ":#{userhost(nick)} JOIN :0,#{ping},#{bool01(op)},#{bool01(fresh)} #{Irc.escape(chan)}"
  end

  # JOINGAME echo: metadata token[5]=ping, token[6]=fresh.
  defp joingame_line(nick, chan, ping, fresh) do
    ":#{userhost(nick)} JOINGAME 0 0 0 0 0 #{ping} #{bool01(fresh)} :#{Irc.escape(chan)}"
  end

  defp part_line(nick, chan), do: ":#{userhost(nick)} PART #{Irc.escape(chan)}"

  defp relay(st, pid, chan, line_fun) do
    with {:ok, sess} <- session(st, pid),
         %{} = ch <- Map.get(st.channels, chan),
         true <- member?(ch, sess.nick) do
      broadcast(ch, line_fun.(sess.nick), except: pid)
      {:reply, :ok, st}
    else
      _ -> {:reply, :ok, st}
    end
  end

  # The quick-match queue id (e.g. 50/51) from the `#Lob <id> 0` channel the
  # player is currently in, or nil.
  defp qm_channel_id(st, nick) do
    Enum.find_value(st.channels, fn {name, ch} ->
      with true <- member?(ch, nick),
           [_, id] <- Regex.run(~r/^#Lob (\d+) 0$/, name) do
        String.to_integer(id)
      else
        _ -> nil
      end
    end)
  end

  defp deliver_to_nick(st, nick, line) do
    case Map.get(st.sessions, String.downcase(nick)) do
      %{pid: pid} -> push(pid, line)
      _ -> :ok
    end
  end

  defp broadcast(ch, line, opts \\ []) do
    except = Keyword.get(opts, :except)

    for {_k, %{pid: pid}} <- ch.members, pid != except do
      push(pid, line)
    end

    :ok
  end

  defp remove_pid(st, pid) do
    case Map.get(st.pids, pid) do
      nil ->
        st

      key ->
        nick = st.sessions[key].nick
        Chronodivexd.Wol.MatchBot.player_left(pid)

        st =
          Enum.reduce(Map.keys(st.channels), st, fn chan, st ->
            ch = Map.get(st.channels, chan)

            if ch && member?(ch, nick) do
              broadcast(ch, part_line(nick, chan), except: pid)
              drop_member(st, chan, nick)
            else
              st
            end
          end)

        %{st | sessions: Map.delete(st.sessions, key), pids: Map.delete(st.pids, pid)}
    end
  end

  # ----- formatting / misc -----

  defp srv, do: Application.fetch_env!(:chronodivexd, :server_name)
  defp userhost(nick), do: "#{nick}!u@h"
  defp bool01(true), do: 1
  defp bool01(_), do: 0
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp push(pid, line), do: send(pid, {:wol_out, line})

  defp err(pid, nick, code, target, msg) do
    push(pid, ":#{srv()} #{code} #{nick} #{target} :#{msg}")
  end

  defp gen_game_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
