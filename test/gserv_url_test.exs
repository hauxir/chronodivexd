defmodule Chronodivexd.Wol.GservUrlTest do
  # async: false — these toggle the shared :gserv_host/:gserv_scheme app env.
  use ExUnit.Case, async: false
  alias Chronodivexd.Wol.GservUrl

  setup do
    # Default deployment config leaves both unset so the URL derives from origin.
    prev_host = Application.get_env(:chronodivexd, :gserv_host)
    prev_scheme = Application.get_env(:chronodivexd, :gserv_scheme)
    Application.put_env(:chronodivexd, :gserv_host, nil)
    Application.put_env(:chronodivexd, :gserv_scheme, nil)

    on_exit(fn ->
      Application.put_env(:chronodivexd, :gserv_host, prev_host)
      Application.put_env(:chronodivexd, :gserv_scheme, prev_scheme)
    end)

    :ok
  end

  test "derives host and scheme from the client's WOL origin" do
    assert GservUrl.build(%{host: "cd.example.com", scheme: "wss"}) ==
             "wss://cd.example.com/gserv"
  end

  test "falls back to literal defaults when nothing is known" do
    assert GservUrl.build(%{}) == "ws://localhost:4000/gserv"
    assert GservUrl.build(nil) == "ws://localhost:4000/gserv"
  end

  test "fills in only the missing half of the origin from defaults" do
    assert GservUrl.build(%{host: "lan-host:4000"}) == "ws://lan-host:4000/gserv"
    assert GservUrl.build(%{scheme: "wss"}) == "wss://localhost:4000/gserv"
  end

  test "explicit config overrides the origin" do
    Application.put_env(:chronodivexd, :gserv_host, "fixed.public.name")
    Application.put_env(:chronodivexd, :gserv_scheme, "wss")

    assert GservUrl.build(%{host: "cd.example.com", scheme: "ws"}) ==
             "wss://fixed.public.name/gserv"
  end

  test "config can override host while scheme still derives from origin" do
    Application.put_env(:chronodivexd, :gserv_host, "fixed.public.name")

    assert GservUrl.build(%{host: "ignored", scheme: "wss"}) ==
             "wss://fixed.public.name/gserv"
  end
end
