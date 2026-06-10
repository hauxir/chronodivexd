defmodule Chronodivexd.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.fetch_env!(:chronodivexd, :port)

    listener =
      if Application.get_env(:chronodivexd, :start_server, true) do
        Logger.info("chronodivexd listening on http://0.0.0.0:#{port} (WOL `/`, gserv `/gserv`, register `/register`)")

        [
          {Bandit,
           plug: Chronodivexd.Router,
           scheme: :http,
           port: port,
           # Cap WebSocket message size. The only large legitimate frame is a
           # map transfer (<= 2 MB, MAX_MAP_TRANSFER_BYTES); everything else is
           # tiny. This blocks oversized-frame memory abuse. (Per-IP rate
           # limiting is handled upstream in the reverse proxy.)
           websocket_options: [max_frame_size: 4 * 1024 * 1024],
           # Trim HTTP request line/header limits — the only HTTP route is a
           # tiny JSON `POST /register` and the WS upgrade `GET`.
           http_1_options: [max_request_line_length: 8_192, max_header_length: 8_192]}
        ]
      else
        []
      end

    children =
      [Chronodivexd.Repo, Chronodivexd.Wol.Hub, Chronodivexd.Wol.MatchBot, Chronodivexd.Gserv.Registry] ++ listener

    opts = [strategy: :one_for_one, name: Chronodivexd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
