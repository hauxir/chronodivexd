defmodule Chronodivexd.Account do
  @moduledoc "Ecto schema for a registered account."
  use Ecto.Schema

  schema "accounts" do
    field :name, :string
    field :name_lower, :string
    field :pass_hash, :string
    field :locale, :string
    timestamps(type: :utc_datetime)
  end
end
