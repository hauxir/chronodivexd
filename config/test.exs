import Config

# Unit tests don't need the HTTP/WS listener (and the dev server may hold the
# port). Protocol-level checks run via the standalone smoke script instead.
config :chronodivexd, start_server: false

config :chronodivexd, Chronodivexd.Repo,
  database: Path.expand("../priv/chronodivexd_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning
