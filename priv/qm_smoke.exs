# Quick-match (matchbot) smoke test — 1v1 and random 2v2.
# Needs the server started WITH a >=4-slot template so both queues are enabled:
#
#   QM_TEMPLATE="...maxSlots=8...:host,...:@:," PORT=44524 ... mix run --no-halt
#   mix run --no-start priv/qm_smoke.exs

Code.require_file("test/support/ws_client.ex", File.cwd!())
alias Chronodivexd.Test.WsClient

port = 4000
b64 = fn s -> Base.encode64(s) end

register = fn u ->
  System.cmd("curl", ["-s", "-X", "POST", "http://localhost:#{port}/register",
    "-d", Jason.encode!(%{user: u, pass: "password1", locale: "en-US"})])
end

assert = fn c, msg -> if c, do: IO.puts("  ✓ #{msg}"), else: (IO.puts("  ✗ FAIL: #{msg}"); System.halt(1)) end
texts = fn frames ->
  frames |> Enum.flat_map(fn {:text, p} -> String.split(p, ~r/\r?\n/); _ -> [] end) |> Enum.reject(&(&1 == ""))
end
has = fn frames, sub -> Enum.any?(texts.(frames), &String.contains?(&1, sub)) end

login = fn nick ->
  c = WsClient.connect(port)
  WsClient.send_text(c, "cvers 1.0.0 16640"); {c, _} = WsClient.drain(c, 300)
  WsClient.send_text(c, "pass #{b64.("password1")}\r\nnick #{nick}\r\nuser U H irc.westwood.com :R")
  {c, _} = WsClient.drain(c, 400)
  c
end

pass = "zotclot9"
# Keep nicks <= 15 chars (MAX_USERNAME_LEN): short run-unique suffix.
suffix = System.system_time(:second) |> Integer.to_string() |> String.slice(-5..-1)

# Run a queue scenario: n players on channel #Lob <chan_id> 0. Assert all get
# Working then Matched then the same STARTG. Returns {game_id, [nicks]}.
run_queue = fn label, chan_id, n ->
  IO.puts("\n== #{label}: #{n} players queue on channel #{chan_id} ==")
  nicks = for i <- 1..n, do: "q#{chan_id}_#{i}_#{suffix}"
  for nk <- nicks, do: register.(nk)

  clients =
    for nk <- nicks do
      c = login.(nk)
      WsClient.send_text(c, "join #Lob_#{chan_id}_0 #{pass}"); {c, _} = WsClient.drain(c, 400)
      WsClient.send_text(c, "privmsg matchbot :ListQueues"); {c, _} = WsClient.drain(c, 300)
      WsClient.send_text(c, "privmsg matchbot :Match COU=-1, COL=-1, VRS=1.0.0, MOD=0, RKD=0")
      # The Nth Match triggers pairing, so this player may receive Working AND
      # Matched in the same drain — keep these frames for the union below.
      {c, f} = WsClient.drain(c, 600)
      assert.(has.(f, ":Working"), "#{nk} got Working")
      {nk, c, f}
    end

  # Collect remaining frames (Matched if not already seen, then STARTG after the
  # countdown) and assert on the union.
  results =
    for {nk, c, early} <- clients do
      {c, f} = WsClient.drain(c, 7000)
      all = early ++ f
      assert.(has.(all, "Matched"), "#{nk} got Matched")
      startg = texts.(all) |> Enum.find(&String.contains?(&1, "STARTG"))
      assert.(startg != nil, "#{nk} got STARTG")
      {nk, c, startg}
    end

  game_ids =
    results
    |> Enum.map(fn {_nk, _c, sg} -> Regex.run(~r/STARTG \S+ :(\S+) \d+/, sg) |> Enum.at(1) end)
    |> Enum.uniq()

  assert.(length(game_ids) == 1, "#{label}: all players got the SAME instance")
  for {_nk, c, _} <- results, do: WsClient.close(c)
  {hd(game_ids), nicks}
end

gserv_join = fn nick, game_id ->
  g = WsClient.connect(port, "/gserv")
  WsClient.send_text(g, "cvers 1.0.0 2"); {g, _} = WsClient.drain(g, 300)
  WsClient.send_text(g, "user #{nick} #{b64.("password1")}"); {g, _} = WsClient.drain(g, 300)
  WsClient.send_text(g, "join #{game_id} 1.0.0 0"); {g, f} = WsClient.drain(g, 500)
  assert.(has.(f, " 400 "), "#{nick}: gserv-joined (400)")
  g
end

# Extract the mapName field (meta index 16) from a `:500 :<opts>` reply.
map_name = fn frames ->
  line = texts.(frames) |> Enum.find(&String.contains?(&1, " 500 "))
  opts = Regex.run(~r/ 500 \S+ :(.*)$/, line) |> Enum.at(1)
  opts |> String.split(":") |> hd() |> String.split(",") |> Enum.at(16)
end

# When a map pool is configured (QM_MAPS_FILE), the matchbot must pick from it.
pool_1v1 = ["MP01T.MAP", "MP05T.MAP"]
pool_2v2 = ["MP04T.MAP", "MP08T.MAP"]
check_maps = System.get_env("QM_MAPS_FILE") != nil

# ---- 1v1 ----
{g1, _} = run_queue.("1v1", 50, 2)
ga = gserv_join.("q50_1_#{suffix}", g1)
WsClient.send_text(ga, "gameopts"); {ga, f} = WsClient.drain(ga, 400)
assert.(String.contains?(Enum.join(texts.(f), "\n"), "q50_1_#{suffix}"), "1v1 opts name players")
if check_maps do
  m = map_name.(f)
  IO.puts("  1v1 map: #{m}")
  assert.(m in pool_1v1, "1v1 map came from the configured pool")
end
WsClient.close(ga)

# ---- random 2v2 ----
{g2, nicks2} = run_queue.("2v2", 51, 4)
gb = gserv_join.(hd(nicks2), g2)
WsClient.send_text(gb, "gameopts"); {gb, f} = WsClient.drain(gb, 400)
opts_line = texts.(f) |> Enum.find(&String.contains?(&1, " 500 "))
assert.(opts_line != nil, "2v2 gameopts returned")
# Extract the opts payload (after ":cdserv 500 x :"), then the humans section.
opts = Regex.run(~r/ 500 \S+ :(.*)$/, opts_line) |> Enum.at(1)
humans = opts |> String.split(":") |> Enum.at(1)
teams =
  humans |> String.split(",") |> Enum.chunk_every(8) |> Enum.filter(&(length(&1) == 8))
  |> Enum.map(&Enum.at(&1, 4))
IO.puts("  2v2 teams: #{inspect(teams)}")
assert.(teams == ["0", "0", "1", "1"], "2v2 assigns teams 0,0,1,1")
if check_maps do
  m = opts |> String.split(":") |> hd() |> String.split(",") |> Enum.at(16)
  IO.puts("  2v2 map: #{m}")
  assert.(m in pool_2v2, "2v2 map came from the configured pool")
end
WsClient.close(gb)

IO.puts("\nALL QUICK-MATCH (1v1 + 2v2) SMOKE CHECKS PASSED ✓")
