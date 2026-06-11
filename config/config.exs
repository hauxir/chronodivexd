import Config

config :chronodivexd,
  ecto_repos: [Chronodivexd.Repo],
  # Port the Bandit listener binds to (HTTP /register + WOL `/` + gserv `/gserv`).
  port: 4000,
  # Host[:port] the client is told to reach gserv on (handed out in STARTG). Left
  # unset so it auto-derives from the Host header of each client's WOL connection
  # — gserv lives on the same listener, so "the host you reached us on" is correct
  # for local/LAN play with no config. Set explicitly (env GSERV_HOST, e.g.
  # "cd.example.com") only when clients must reach gserv at a fixed public name
  # that differs from their WOL Host header.
  gserv_host: nil,
  # ws or wss — scheme of the STARTG gserv URL. Unset → derived from the WOL
  # request (X-Forwarded-Proto / TLS). Set "wss" (env GSERV_SCHEME) to force it.
  gserv_scheme: nil,
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
