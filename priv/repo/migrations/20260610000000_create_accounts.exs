defmodule Chronodivexd.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :name, :string, null: false
      add :name_lower, :string, null: false
      add :pass_hash, :string, null: false
      add :locale, :string
      timestamps(type: :utc_datetime)
    end

    # Westwood nicks are case-insensitive for uniqueness; we key on the
    # lower-cased name but keep the original casing for display.
    create unique_index(:accounts, [:name_lower])
  end
end
