defmodule Chronodivexd.Repo do
  use Ecto.Repo,
    otp_app: :chronodivexd,
    adapter: Ecto.Adapters.SQLite3
end
