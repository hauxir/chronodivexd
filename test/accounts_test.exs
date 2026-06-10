defmodule Chronodivexd.AccountsTest do
  use ExUnit.Case, async: false
  alias Chronodivexd.{Accounts, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "create + verify round-trip" do
    assert :ok = Accounts.create("Alice", "password1", "en-US")
    assert {:ok, "Alice"} = Accounts.verify("Alice", "password1")
    # nick is case-insensitive
    assert {:ok, "Alice"} = Accounts.verify("alice", "password1")
    assert :error = Accounts.verify("Alice", "wrongpass1")
    assert :error = Accounts.verify("nobody", "password1")
  end

  test "duplicate nick (case-insensitive) is rejected" do
    assert :ok = Accounts.create("Bob", "password1", nil)
    assert {:error, _} = Accounts.create("bob", "password1", nil)
  end

  test "validation rules" do
    assert {:error, _} = Accounts.create("a", "password1", nil)
    assert {:error, _} = Accounts.create("ok", "short", nil)
    assert {:error, _} = Accounts.create("bad nick", "password1", nil)
  end

  test "hash format and verify_hash" do
    h = Accounts.hash_password("hunter22")
    assert String.starts_with?(h, "pbkdf2$sha256$")
    assert Accounts.verify_hash("hunter22", h)
    refute Accounts.verify_hash("hunter23", h)
  end
end
