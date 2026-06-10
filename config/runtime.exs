import Config

# Allow overriding the network bits at runtime via environment variables, so the
# same release works whether the browser reaches us on localhost or a LAN/host IP.
if port = System.get_env("PORT") do
  config :chronodivexd, port: String.to_integer(port)
end

if gserv_host = System.get_env("GSERV_HOST") do
  config :chronodivexd, gserv_host: gserv_host
end

if gserv_scheme = System.get_env("GSERV_SCHEME") do
  config :chronodivexd, gserv_scheme: gserv_scheme
end

if db = System.get_env("DATABASE_PATH") do
  config :chronodivexd, Chronodivexd.Repo, database: db
end

if tmpl = System.get_env("QM_TEMPLATE") do
  config :chronodivexd, quick_match_template: tmpl
end

if maps = System.get_env("QM_MAPS_FILE") do
  config :chronodivexd, quick_match_maps_file: maps
end
