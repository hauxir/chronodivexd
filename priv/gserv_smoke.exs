# gserv (in-game relay) smoke test. Run against a running chronodivexd:
#
#     mix run --no-start priv/gserv_smoke.exs
#
# Simulates a 2-player match: host creates the instance + uploads the map,
# joiner joins + downloads it, both load → NET_RATE + GAME_START, then both
# exchange turn-0 actions and must receive the aggregated relay frame.

Code.require_file("test/support/ws_client.ex", File.cwd!())
alias Chronodivexd.Test.WsClient

port = 4000
b64 = fn s -> Base.encode64(s) end

register = fn user ->
  body = Jason.encode!(%{user: user, pass: "password1", locale: "en-US"})
  System.cmd("curl", ["-s", "-X", "POST", "http://localhost:#{port}/register", "-d", body])
end

assert = fn cond, msg ->
  if cond, do: IO.puts("  ✓ #{msg}"), else: (IO.puts("  ✗ FAIL: #{msg}"); System.halt(1))
end

texts = fn frames ->
  frames
  |> Enum.flat_map(fn
    {:text, p} -> String.split(p, ~r/\r?\n/)
    _ -> []
  end)
  |> Enum.reject(&(&1 == ""))
end

bins = fn frames -> for {:binary, b} <- frames, do: b end
# Match a numeric reply code as a whole token (it may be the last token, e.g.
# GAME_START is just ":cdserv 700" with no params).
has_code = fn frames, code ->
  re = ~r/(^|\s)#{code}(\s|$)/
  Enum.any?(texts.(frames), &Regex.match?(re, &1))
end

login = fn c, name ->
  WsClient.send_text(c, "cvers 1.0.0 2")
  {c, _} = WsClient.drain(c, 400)
  WsClient.send_text(c, "user #{name} #{b64.("password1")}")
  {c, f} = WsClient.drain(c, 400)
  assert.(has_code.(f, 100), "#{name}: logged in (100)")
  c
end

suffix = Integer.to_string(System.system_time(:second))
host = "h#{suffix}"
join = "j#{suffix}"
register.(host)
register.(join)
IO.puts("Players: #{host} / #{join}")

game_id = "game-" <> suffix
opts = "0:#{host},0,0,0,0,0,0,0,#{join},0,0,0,0,0,0,0:@:,"
map_bytes = "MAPDATA-" <> suffix
prefix = 2

IO.puts("\n== Host creates instance + uploads map ==")
h = WsClient.connect(port, "/gserv")
h = login.(h, host)
WsClient.send_text(h, "create #{game_id} 123 #{opts} 1.0.0 0 0")
{h, f} = WsClient.drain(h, 400)
assert.(has_code.(f, 200), "host: instance created (200)")
WsClient.send_text(h, "gameopts")
{h, f} = WsClient.drain(h, 400)
assert.(Enum.any?(texts.(f), &String.contains?(&1, opts)), "host: gameopts echoed (500)")
WsClient.send_binary(h, <<prefix, 3, map_bytes::binary>>)
WsClient.send_text(h, "loaded 100")
{h, _} = WsClient.drain(h, 400)

IO.puts("\n== Joiner joins + downloads map ==")
j = WsClient.connect(port, "/gserv")
j = login.(j, join)
WsClient.send_text(j, "join #{game_id} 1.0.0 0")
{j, f} = WsClient.drain(j, 400)
assert.(has_code.(f, 400), "joiner: connected to instance (400)")
WsClient.send_text(j, "gameopts")
{j, _} = WsClient.drain(j, 400)
WsClient.send_binary(j, <<prefix, 4>>)
{j, f} = WsClient.drain(j, 600)
map_reply = bins.(f) |> Enum.find(&match?(<<2, 2, _::binary>>, &1))
assert.(map_reply == <<2, 2>> <> map_bytes, "joiner: received correct map via GET_MAP")

IO.puts("\n== Both load → NET_RATE + GAME_START ==")
WsClient.send_text(j, "loaded 100")
{j, jf} = WsClient.drain(j, 600)
{h, hf} = WsClient.drain(h, 600)
assert.(has_code.(jf, 802) and has_code.(jf, 700), "joiner: got NET_RATE (802) + GAME_START (700)")
assert.(has_code.(hf, 802) and has_code.(hf, 700), "host: got NET_RATE (802) + GAME_START (700)")

IO.puts("\n== Lockstep turn-0 action relay ==")
# payload = serializePlayerActions([{id:9,len:0}]) = <<count=1, id=9, len=0::16le>>
payload = <<1, 9, 0::little-16>>
WsClient.send_binary(h, <<prefix, 1, 0::little-32, payload::binary>>)
{h, _} = WsClient.drain(h, 300)
WsClient.send_binary(j, <<prefix, 1, 0::little-32, payload::binary>>)
{j, jf} = WsClient.drain(j, 600)
{h, hf} = WsClient.drain(h, 600)

check_relay = fn frames, who ->
  frame = bins.(frames) |> Enum.find(&match?(<<2, 1, _::binary>>, &1))
  assert.(frame != nil, "#{who}: received aggregated actions frame")
  <<2, 1, turn::little-32, count::8, _rest::binary>> = frame
  assert.(turn == 0, "#{who}: relay turn == 0")
  assert.(count == 2, "#{who}: relay includes both players (count=2)")
end

check_relay.(hf, "host")
check_relay.(jf, "joiner")

WsClient.close(h)
WsClient.close(j)
IO.puts("\nALL GSERV SMOKE CHECKS PASSED ✓")
