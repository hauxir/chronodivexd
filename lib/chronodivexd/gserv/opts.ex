defmodule Chronodivexd.Gserv.Opts do
  @moduledoc """
  Parse the serialized game-options string to recover the ordered human-player
  names — the basis for assigning each connection a `playerId`.

  The string is `<meta>:<humanPlayers>:@:<aiPlayers>,`. The `<humanPlayers>` section is the
  human players' fields concatenated, 8 comma-separated fields per player
  (`name,country,color,startPos,team,0,0,0`). The engine creates players in the
  order `[...humanPlayers, ...aiPlayers]` and the
  action relay keys players by that index, so a
  human's `playerId` is simply its position in the human list.
  """

  @doc "Ordered list of human player names (index = playerId)."
  @spec player_names(String.t()) :: [String.t()]
  def player_names(opts) when is_binary(opts) do
    case String.split(opts, ":") do
      [_meta, humans | _rest] ->
        humans
        |> String.split(",")
        |> Enum.chunk_every(8)
        |> Enum.filter(&(length(&1) == 8))
        |> Enum.map(&hd/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  def player_names(_), do: []

  @doc "Map of downcased name => playerId."
  @spec player_ids(String.t()) :: %{optional(String.t()) => non_neg_integer()}
  def player_ids(opts) do
    opts
    |> player_names()
    |> Enum.with_index()
    |> Map.new(fn {name, idx} -> {String.downcase(name), idx} end)
  end
end
