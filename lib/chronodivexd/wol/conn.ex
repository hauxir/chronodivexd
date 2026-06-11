defmodule Chronodivexd.Wol.Conn do
  @moduledoc """
  WebSock handler for a single WOL (lobby) connection. Parses the IRC-like
  command lines the client sends, drives
  `Chronodivexd.Wol.Hub`, and writes outbound lines. Every outbound line is funneled
  through the process mailbox as `{:wol_out, line}` so ordering between local
  replies and Hub broadcasts is preserved.
  """
  @behaviour WebSock
  require Logger

  alias Chronodivexd.{Accounts, Irc}
  alias Chronodivexd.Wol.{Codes, Hub}

  defmodule State do
    @moduledoc false
    # `origin` = %{host, scheme} the client reached us on, captured at the WS
    # upgrade and used to advertise gserv (same listener) in STARTG.
    defstruct nick: nil, pending_nick: nil, pending_pass: nil, locale: "en-US", origin: %{}
  end

  @impl true
  def init(opts), do: {:ok, %State{origin: Map.get(opts, :origin, %{})}}

  @impl true
  # WOL commands are short lines; the only large frames on this listener are
  # gserv map transfers (a different endpoint). Drop oversized WOL frames so a
  # huge line can't be stored (topic/chat) and fanned out to a channel.
  @max_frame_bytes 16_384

  def handle_in({data, [opcode: :text]}, state) when byte_size(data) > @max_frame_bytes,
    do: {:ok, state}

  def handle_in({data, [opcode: :text]}, state) do
    state =
      data
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(state, &dispatch/2)

    {:ok, state}
  end

  def handle_in({_data, [opcode: _other]}, state), do: {:ok, state}

  @impl true
  def handle_info({:wol_out, line}, state), do: {:push, {:text, line <> "\r\n"}, state}
  def handle_info(:replaced, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state) do
    Hub.disconnect(self())
    :ok
  end

  # ----- command dispatch -----

  defp dispatch(line, state) do
    {cmd, rest} = split_cmd(line)

    case String.downcase(cmd) do
      "cvers" -> reply(":#{srv()} #{Codes.rpl_cvers_ok()} * :ok"); state
      "setlocale" -> handle_setlocale(rest, state)
      "getlocale" -> handle_getlocale(rest, state)
      "pass" -> %{state | pending_pass: decode_pass(first_arg(rest))}
      "nick" -> %{state | pending_nick: first_arg(rest)}
      "user" -> handle_login(state)
      "ping" -> reply(":#{srv()} PONG #{srv()} :#{strip_colon(String.trim(rest))}"); state
      "pong" -> state
      "join" -> guard(state, fn -> handle_join(rest, state) end)
      "names" -> guard(state, fn -> Hub.names(self(), Irc.unescape(first_arg(rest))) end)
      "list" -> guard(state, fn -> Hub.list_games(self()) end)
      "joingame" -> guard(state, fn -> handle_joingame(rest, state) end)
      "gameopt" -> guard(state, fn -> handle_gameopt(rest) end)
      "topic" -> guard(state, fn -> handle_topic(rest) end)
      "mode" -> guard(state, fn -> handle_mode(rest) end)
      "kick" -> guard(state, fn -> handle_kick(rest) end)
      "part" -> guard(state, fn -> Hub.part_channel(self(), Irc.unescape(first_arg(rest))) end)
      "privmsg" -> guard(state, fn -> handle_privmsg(rest) end)
      "page" -> guard(state, fn -> handle_page(rest, "PAGE") end)
      "notice" -> guard(state, fn -> handle_page(rest, "NOTICE") end)
      "startg" -> guard(state, fn -> handle_startg(rest) end)
      "gping" -> state
      "quit" -> state
      _ ->
        if String.starts_with?(String.downcase(cmd), "party") do
          state
        else
          Logger.debug("WOL: ignoring unknown command #{inspect(line)}")
          state
        end
    end
  end

  # Run `fun` (which returns anything) only when logged in; always returns state.
  defp guard(%State{nick: nil} = state, _fun), do: state

  defp guard(state, fun) do
    fun.()
    state
  end

  defp handle_setlocale(rest, state) do
    locale = first_arg(rest)
    reply(":#{srv()} #{Codes.rpl_set_locale()} * #{locale}")
    %{state | locale: locale}
  end

  defp handle_getlocale(rest, state) do
    nick = first_arg(rest)
    reply(":#{srv()} #{Codes.rpl_get_locale()} #{nick} x `#{state.locale}`")
    state
  end

  defp handle_login(%State{pending_nick: nil} = state) do
    reply(":#{srv()} #{Codes.rpl_bad_login()} * x :Missing nickname")
    state
  end

  defp handle_login(state) do
    case Accounts.verify(state.pending_nick, state.pending_pass || "") do
      {:ok, nick} ->
        Hub.login(nick, self(), false, state.origin)
        send_motd(nick)
        Logger.info("WOL login: #{nick}")
        %{state | nick: nick, pending_pass: nil}

      :error ->
        reply(":#{srv()} #{Codes.rpl_bad_login()} #{state.pending_nick} x :Invalid nickname or password")
        state
    end
  end

  defp send_motd(nick) do
    reply(":#{srv()} #{Codes.rpl_motdstart()} #{nick} :- Chrono Divide (chronodivexd)")
    reply(":#{srv()} #{Codes.rpl_motd()} #{nick} :- Welcome, #{nick}!")
    reply(":#{srv()} #{Codes.rpl_endofmotd()} #{nick} :End of MOTD")
  end

  defp handle_join(rest, _state) do
    case String.split(rest, " ", trim: true) do
      [chan | key_rest] -> Hub.join_channel(self(), Irc.unescape(chan), Enum.at(key_rest, 0))
      _ -> :ok
    end
  end

  # create: `joingame <chan> 1 9 <type> <tourney> 0 <res> 0 [pass]` (>= 8 args)
  # join:   `joingame <chan> <observer> [pass]`                     (2-3 args)
  defp handle_joingame(rest, _state) do
    args = String.split(rest, " ", trim: true)

    case args do
      [chan, _a, _b, type, tourney, _z, res, _zz | pass_rest] ->
        meta = %{
          tournament: tourney == "1",
          res_locked: res == "1",
          type: parse_int(type, 45),
          pass: Enum.at(pass_rest, 0)
        }

        Hub.create_game(self(), Irc.unescape(chan), meta)

      [chan | tail] ->
        observer? = Enum.at(tail, 0) == "1"
        key = Enum.at(tail, 1)
        Hub.join_game(self(), Irc.unescape(chan), observer?, key)

      _ ->
        :ok
    end
  end

  defp handle_gameopt(rest) do
    {target, opt} = split_target_and_text(rest)
    Hub.gameopt(self(), Irc.unescape(target), opt)
  end

  defp handle_topic(rest) do
    {target, topic} = split_target_and_text(rest)
    Hub.set_topic(self(), Irc.unescape(target), topic)
  end

  defp handle_mode(rest) do
    case String.split(rest, " ", trim: true) do
      [chan, "+l", n | _] -> Hub.set_mode_limit(self(), Irc.unescape(chan), parse_int(n, 0))
      _ -> :ok
    end
  end

  defp handle_kick(rest) do
    # kick <chan> <nick1,nick2> :<reason>
    {head, reason} = split_text(rest)

    case String.split(head, " ", trim: true) do
      [chan, nicks | _] -> Hub.kick(self(), Irc.unescape(chan), String.split(nicks, ","), reason || "")
      _ -> :ok
    end
  end

  defp handle_privmsg(rest) do
    {targets, text} = split_target_and_text(rest)
    Hub.privmsg(self(), String.split(targets, ","), text)
  end

  defp handle_page(rest, verb) do
    {target, text} = split_target_and_text(rest)
    Hub.page(self(), target, text, verb)
  end

  defp handle_startg(rest) do
    case String.split(rest, " ", trim: true) do
      [chan, players | _] -> Hub.start_game(self(), Irc.unescape(chan), String.split(players, ","))
      [chan] -> Hub.start_game(self(), Irc.unescape(chan), [])
      _ -> :ok
    end
  end

  # ----- parsing helpers -----

  defp split_cmd(line) do
    case String.split(line, " ", parts: 2) do
      [cmd, rest] -> {cmd, rest}
      [cmd] -> {cmd, ""}
    end
  end

  defp first_arg(rest), do: rest |> String.split(" ", trim: true) |> List.first() || ""

  # Split "<target> :<text>" → {target, text}. Falls back to whole string as target.
  defp split_target_and_text(rest) do
    case String.split(rest, " :", parts: 2) do
      [target, text] -> {String.trim(target), text}
      [target] -> {String.trim(target), ""}
    end
  end

  # Split off a trailing " :<text>" → {head_without_text, text_or_nil}.
  defp split_text(rest) do
    case String.split(rest, " :", parts: 2) do
      [head, text] -> {head, text}
      [head] -> {head, nil}
    end
  end

  defp strip_colon(":" <> rest), do: rest
  defp strip_colon(s), do: s

  defp decode_pass(b64) do
    case Base.decode64(b64) do
      {:ok, pass} -> pass
      :error -> ""
    end
  end

  defp parse_int(s, default) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp reply(line), do: send(self(), {:wol_out, line})
  defp srv, do: Application.fetch_env!(:chronodivexd, :server_name)
end
