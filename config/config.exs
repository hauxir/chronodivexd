import Config

config :chronodivexd,
  ecto_repos: [Chronodivexd.Repo],
  # Port the Bandit listener binds to (HTTP /register + WOL `/` + gserv `/gserv`).
  port: 4000,
  # Host[:port] the client should be told to reach gserv on (handed out in
  # STARTG). Must be reachable from the browser. Behind a TLS reverse proxy set
  # this to your public host (e.g. "cd.example.com") and gserv_scheme to "wss".
  gserv_host: "localhost:4000",
  # ws or wss — the scheme of the STARTG gserv URL. Use wss behind TLS/Caddy.
  gserv_scheme: "ws",
  # WOL/gserv server name token used as the IRC line prefix (`:cdserv ...`).
  server_name: "cdserv",
  # Optional fallback game-options string for quick match before any custom game
  # has been played (the matchbot otherwise auto-captures one from a custom game
  # with an official map). Set via QM_TEMPLATE.
  quick_match_template: nil,
  # Path to a bnmaps-style map pool used to pick/rotate the quick-match map
  # (like the original server's conf/bnmaps.conf). Each line:
  #   <queue> <map-filename> [maxslots]      e.g.  1v1 MP01T.MAP 2
  # `#` comments and blank lines ignored. The captured/template options supply
  # all other settings; only the map (and optional slot count) are swapped in.
  # Set via QM_MAPS_FILE. When unset, the matchbot reuses the template's own map.
  quick_match_maps_file: nil

config :chronodivexd, Chronodivexd.Repo,
  database: Path.expand("../priv/chronodivexd.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal

config :logger, level: :info

import_config "#{config_env()}.exs"
