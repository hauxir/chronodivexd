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
        [{Bandit, plug: Chronodivexd.Router, scheme: :http, port: port}]
      else
        []
      end

    children =
      [Chronodivexd.Repo, Chronodivexd.Wol.Hub, Chronodivexd.Wol.MatchBot, Chronodivexd.Gserv.Registry] ++ listener

    opts = [strategy: :one_for_one, name: Chronodivexd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
