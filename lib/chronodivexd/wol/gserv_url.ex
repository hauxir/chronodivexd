defmodule Chronodivexd.Wol.GservUrl do
  @moduledoc """
  Builds the gserv WebSocket URL handed to the client in `STARTG`.

  gserv is served on the *same* Bandit listener as the WOL connection, so by
  default we advertise the very host/scheme the client used to reach us — captured
  from its WOL upgrade request (`origin`, honoring `X-Forwarded-*`). That makes
  local/LAN play zero-config: "the host you reached us on" already points at
  `/gserv`.

  We can't just emit a relative `/gserv`: the client page is served from a
  *different* origin than this server (the static mirror / chronodivide.com), so
  the browser's `new WebSocket(url)` resolves a relative URL against the page, not
  the open WOL socket — it would miss this server entirely.

  Explicit `:gserv_host` / `:gserv_scheme` config (env `GSERV_HOST` / `GSERV_SCHEME`)
  overrides the derived values, for when clients must reach a fixed public name
  that differs from their WOL `Host` header.
  """

  @default_host "localhost:4000"
  @default_scheme "ws"

  @doc """
  `origin` is the `%{host: h, scheme: s}` captured at WOL upgrade (either field
  may be nil/absent). Config overrides win; the literal defaults are the last
  resort when nothing is known.
  """
  def build(origin) do
    origin = origin || %{}
    "#{scheme(origin)}://#{host(origin)}/gserv"
  end

  defp host(origin),
    do: Application.get_env(:chronodivexd, :gserv_host) || origin[:host] || @default_host

  defp scheme(origin),
    do: Application.get_env(:chronodivexd, :gserv_scheme) || origin[:scheme] || @default_scheme
end
