defmodule Chronodivexd.IrcTest do
  use ExUnit.Case, async: true
  alias Chronodivexd.Irc

  test "escapes and unescapes round-trips the lobby channel name" do
    name = "#Lob 45 0"
    assert Irc.escape(name) == "#Lob_45_0"
    assert Irc.unescape(Irc.escape(name)) == name
  end

  test "escapes the special characters per IrcProtocol" do
    assert Irc.escape("a:b,c%d") == "a%=b%-c%%d"
    assert Irc.unescape("a%=b%-c%%d") == "a:b,c%d"
  end

  test "game channel name round-trips" do
    name = "alice's game"
    assert Irc.unescape(Irc.escape(name)) == name
  end
end
