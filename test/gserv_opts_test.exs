defmodule Chronodivexd.Gserv.OptsTest do
  use ExUnit.Case, async: true
  alias Chronodivexd.Gserv.Opts

  test "extracts ordered human player names → playerIds" do
    # <meta>:<humans 8-fields-each>:@:<ai>,
    opts = "0,0,5,10000,10:alice,0,1,2,3,0,0,0,bob,5,4,7,1,0,0,0:@:0,-1,-1,-1,-1,"
    assert Opts.player_names(opts) == ["alice", "bob"]
    assert Opts.player_ids(opts) == %{"alice" => 0, "bob" => 1}
  end

  test "single player" do
    opts = "m:solo,0,0,0,0,0,0,0:@:,"
    assert Opts.player_names(opts) == ["solo"]
    assert Opts.player_ids(opts) == %{"solo" => 0}
  end

  test "tolerates malformed input" do
    assert Opts.player_names("garbage") == []
    assert Opts.player_ids("") == %{}
  end
end
