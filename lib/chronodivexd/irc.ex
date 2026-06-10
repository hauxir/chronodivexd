defmodule Chronodivexd.Irc do
  @moduledoc """
  Westwood channel-name escaping/unescaping and small line helpers.

  The client sends/receives channel names
  in an escaped form (spaces → `_`, etc.); we keep the *unescaped* name as the
  canonical key internally and escape only on the wire.
  """

  @max_channelname_len 30
  def max_channelname_len, do: @max_channelname_len

  @doc "Escape a channel name for the wire."
  def escape(name) do
    name
    |> String.to_charlist()
    |> Enum.map_join("", &escape_char/1)
  end

  defp escape_char(?\s), do: "_"
  defp escape_char(?%), do: "%%"
  defp escape_char(?_), do: "%_"
  defp escape_char(?\b), do: "%b"
  defp escape_char(?\n), do: "%n"
  defp escape_char(?\r), do: "%r"
  defp escape_char(?:), do: "%="
  defp escape_char(?,), do: "%-"
  defp escape_char(c), do: <<c::utf8>>

  @doc "Unescape a wire channel name."
  def unescape(name), do: unescape(String.to_charlist(name), [])

  defp unescape([], acc), do: acc |> Enum.reverse() |> List.to_string()

  defp unescape([?%, c | rest], acc) do
    decoded =
      case c do
        ?b -> ?\b
        ?n -> ?\n
        ?r -> ?\r
        ?= -> ?:
        ?- -> ?,
        other -> other
      end

    unescape(rest, [decoded | acc])
  end

  defp unescape([?_ | rest], acc), do: unescape(rest, [?\s | acc])
  defp unescape([c | rest], acc), do: unescape(rest, [c | acc])
end
