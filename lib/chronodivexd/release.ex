defmodule Chronodivexd.Release do
  @moduledoc """
  Release-time tasks. In a packaged `mix release` (e.g. the Docker image) `mix`
  is unavailable, so migrations are run via this module:

      bin/chronodivexd eval "Chronodivexd.Release.migrate()"
  """
  @app :chronodivexd

  def migrate do
    load_app()

    for repo <- repos() do
      ensure_db_dir(repo)
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  # SQLite won't create intermediate directories for its database file, so make
  # sure the configured DATABASE_PATH's parent exists (e.g. the mounted volume).
  defp ensure_db_dir(repo) do
    case Application.get_env(@app, repo)[:database] do
      path when is_binary(path) -> File.mkdir_p!(Path.dirname(path))
      _ -> :ok
    end
  end
end
