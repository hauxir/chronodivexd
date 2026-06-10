defmodule Chronodivexd.Accounts do
  @moduledoc """
  Account storage + credential verification.

  Passwords are hashed with PBKDF2-HMAC-SHA256 (built into `:crypto`, no NIF
  dependency) using a per-row random salt. The stored string is
  `pbkdf2$sha256$<iterations>$<b64salt>$<b64hash>`.

  Username/length rules :
  nick `^[A-Za-z0-9-_]+$`, 2..15 chars; password 8..128 chars.
  """
  import Ecto.Query, only: [from: 2]
  alias Chronodivexd.{Account, Repo}

  @iterations 100_000
  @keylen 32
  @salt_len 16

  @min_user 2
  @max_user 15
  @min_pass 8
  @max_pass 128

  @doc "Create an account. Returns :ok or {:error, message} (message is shown to the user)."
  @spec create(String.t(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def create(name, pass, locale) do
    with :ok <- validate(name, pass) do
      changeset = %Account{
        name: name,
        name_lower: String.downcase(name),
        pass_hash: hash_password(pass),
        locale: locale
      }

      case Repo.insert(account_changeset(changeset)) do
        {:ok, _} -> :ok
        {:error, _changeset} -> {:error, "That nickname is already taken."}
      end
    end
  end

  @doc "Verify credentials. Returns {:ok, canonical_name} or :error."
  @spec verify(String.t(), String.t()) :: {:ok, String.t()} | :error
  def verify(name, pass) do
    case Repo.one(from a in Account, where: a.name_lower == ^String.downcase(name)) do
      nil ->
        # Run a hash anyway to blunt timing side-channels.
        _ = hash_password(pass)
        :error

      account ->
        if verify_hash(pass, account.pass_hash), do: {:ok, account.name}, else: :error
    end
  end

  @doc "Whether an account exists for the given nick (case-insensitive)."
  def exists?(name) do
    Repo.exists?(from a in Account, where: a.name_lower == ^String.downcase(name))
  end

  defp validate(name, pass) do
    cond do
      not is_binary(name) or not is_binary(pass) ->
        {:error, "Missing username or password."}

      String.length(name) < @min_user or String.length(name) > @max_user ->
        {:error, "Nickname must be #{@min_user}-#{@max_user} characters."}

      not Regex.match?(~r/^[A-Za-z0-9\-_]+$/, name) ->
        {:error, "Nickname may only contain letters, numbers, - and _."}

      String.length(pass) < @min_pass or String.length(pass) > @max_pass ->
        {:error, "Password must be #{@min_pass}-#{@max_pass} characters."}

      true ->
        :ok
    end
  end

  defp account_changeset(account) do
    account
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:name_lower)
  end

  @doc false
  def hash_password(pass) do
    salt = :crypto.strong_rand_bytes(@salt_len)
    hash = :crypto.pbkdf2_hmac(:sha256, pass, salt, @iterations, @keylen)

    "pbkdf2$sha256$#{@iterations}$#{Base.encode64(salt)}$#{Base.encode64(hash)}"
  end

  @doc false
  def verify_hash(pass, stored) do
    case String.split(stored, "$") do
      ["pbkdf2", "sha256", iters, b64salt, b64hash] ->
        with {iterations, ""} <- Integer.parse(iters),
             {:ok, salt} <- Base.decode64(b64salt),
             {:ok, expected} <- Base.decode64(b64hash) do
          actual = :crypto.pbkdf2_hmac(:sha256, pass, salt, iterations, byte_size(expected))
          :crypto.hash_equals(expected, actual)
        else
          _ -> false
        end

      _ ->
        false
    end
  end
end
