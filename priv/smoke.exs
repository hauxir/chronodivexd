# WOL protocol smoke test. Run against a *running* chronodivexd:
#
#     mix run --no-halt            # in one shell (the server)
#     mix run --no-start priv/smoke.exs   # in another (this client)
#
# Drives the full lobby flow for two users (cvers → login → lobby → create →
# join → gameopt relay → startg) and asserts the key server replies.

Code.require_file("test/support/ws_client.ex", File.cwd!())
alias Chronodivexd.Test.WsClient

port = 4000
b64 = fn s -> Base.encode64(s) end

register = fn user, pass ->
  body = Jason.encode!(%{user: user, pass: pass, locale: "en-US"})
  {out, _} = System.cmd("curl", ["-s", "-X", "POST", "http://localhost:#{port}/register", "-d", body])
  out
end

login = fn c, nick, pass ->
  WsClient.send_text(c, "cvers 1.0.0 16640")
  {c, _} = WsClient.recv_lines_until(c, &String.contains?(&1, " 700 "))
  WsClient.send_text(c, "setlocale en-US")
  {c, _} = WsClient.recv_lines_until(c, &String.contains?(&1, " 310 "))
  WsClient.send_text(c, "pass #{b64.(pass)}\r\nnick #{nick}\r\nuser UserName HostName irc.westwood.com :Real")
  {c, motd} = WsClient.recv_lines_until(c, &String.contains?(&1, " 376 "))
  IO.puts("  [#{nick}] logged in; MOTD lines: #{length(motd)}")
  c
end

assert = fn cond, msg ->
  if cond, do: IO.puts("  ✓ #{msg}"), else: (IO.puts("  ✗ FAIL: #{msg}") ; System.halt(1))
end

# Fresh accounts each run.
suffix = Integer.to_string(System.system_time(:second))
alice = "ali#{suffix}"
bob = "bob#{suffix}"
IO.puts("Registering #{alice} / #{bob} ...")
IO.puts("  register a: #{register.(alice, "password1")}")
IO.puts("  register b: #{register.(bob, "password1")}")

lob = "#Lob_45_0"
pass = "zotclot9"

IO.puts("\n== Alice logs in and joins lobby ==")
a = WsClient.connect(port)
a = login.(a, alice, "password1")
WsClient.send_text(a, "join #{lob} #{pass}")
{a, lines} = WsClient.recv_lines_until(a, &String.contains?(&1, " 366 "))
assert.(Enum.any?(lines, &(String.contains?(&1, "JOIN") and String.contains?(&1, lob))), "alice got JOIN echo")
assert.(Enum.any?(lines, &String.contains?(&1, " 353 ")), "alice got NAMES (353)")

WsClient.send_text(a, "list 45 45")
{a, lst} = WsClient.recv_lines_until(a, &String.contains?(&1, " 323 "))
assert.(Enum.any?(lst, &String.contains?(&1, " 321 ")), "list start (321)")
assert.(not Enum.any?(lst, &String.contains?(&1, " 326 ")), "no games listed yet")

IO.puts("\n== Alice creates a game ==")
egame = "#{alice}'s_game"
WsClient.send_text(a, "joingame #{egame} 1 9 45 0 0 0 0")
{a, cg} = WsClient.recv_lines_until(a, &String.contains?(&1, " 366 "))
assert.(Enum.any?(cg, &(String.contains?(&1, "JOINGAME") and String.contains?(&1, egame))), "alice got JOINGAME echo")
assert.(Enum.any?(cg, &String.contains?(&1, "@#{alice}")), "alice is operator in NAMES")

# Host sets a topic so the game becomes listable.
topic = "g30N39,0,0,2,0,#{egame},,"
WsClient.send_text(a, "topic #{egame} :#{topic}")

IO.puts("\n== Bob logs in, joins lobby, sees the game ==")
bo = WsClient.connect(port)
bo = login.(bo, bob, "password1")
WsClient.send_text(bo, "join #{lob} #{pass}")
{bo, _} = WsClient.recv_lines_until(bo, &String.contains?(&1, " 366 "))
WsClient.send_text(bo, "list 45 45")
{bo, lst2} = WsClient.recv_lines_until(bo, &String.contains?(&1, " 323 "))
game_line = Enum.find(lst2, &String.contains?(&1, " 326 "))
assert.(game_line != nil, "bob sees the game (326)")
assert.(game_line != nil and String.contains?(game_line, egame), "game line names the channel")
IO.puts("  game line: #{game_line}")

IO.puts("\n== Bob joins the game ==")
WsClient.send_text(bo, "joingame #{egame} 0")
{bo, bj} = WsClient.recv_lines_until(bo, &String.contains?(&1, " 366 "))
assert.(Enum.any?(bj, &(String.contains?(&1, "JOINGAME") and String.contains?(&1, egame))), "bob got JOINGAME echo")
assert.(Enum.any?(bj, &String.contains?(&1, "@#{alice}")), "bob sees host as operator")
# Alice should be notified that bob joined.
{a, aj} = WsClient.recv_lines_until(a, &String.contains?(&1, "JOINGAME"))
assert.(Enum.any?(aj, &String.contains?(&1, bob)), "alice notified of bob JOINGAME")

IO.puts("\n== gameopt relay ==")
WsClient.send_text(a, "gameopt #{egame} :A1")
{bo, go} = WsClient.recv_lines_until(bo, &String.contains?(&1, "GAMEOPT"))
assert.(Enum.any?(go, &(String.contains?(&1, "GAMEOPT") and String.contains?(&1, ":A1"))), "bob received alice's GAMEOPT :A1")

IO.puts("\n== startg → STARTG ==")
WsClient.send_text(a, "startg #{egame} #{alice},#{bob}")
{_bo, sg} = WsClient.recv_lines_until(bo, &String.contains?(&1, "STARTG"))
startg = Enum.find(sg, &String.contains?(&1, "STARTG"))
assert.(startg != nil and String.contains?(startg, "/gserv"), "bob received STARTG with gserv url")
IO.puts("  STARTG: #{startg}")

WsClient.close(a)
WsClient.close(bo)
IO.puts("\nALL WOL SMOKE CHECKS PASSED ✓")
