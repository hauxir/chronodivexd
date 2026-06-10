defmodule Chronodivexd.Test.WsClient do
  @moduledoc """
  Tiny synchronous WebSocket client over `:gen_tcp` for tests. Enough of
  RFC 6455 to drive our text+binary protocols: masked client frames, unmasked
  server frames, single-frame messages.
  """
  import Bitwise
  @magic "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defstruct [:socket, buffer: <<>>]

  def connect(port, path \\ "/") do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    :ok = :gen_tcp.send(socket, req)
    {headers, rest} = read_until_headers(socket, <<>>)
    expected = Base.encode64(:crypto.hash(:sha, key <> @magic))
    true = String.contains?(headers, expected)
    %__MODULE__{socket: socket, buffer: rest}
  end

  def send_text(c, text), do: :gen_tcp.send(c.socket, frame(0x1, text))
  def send_binary(c, data), do: :gen_tcp.send(c.socket, frame(0x2, data))
  def close(c), do: :gen_tcp.close(c.socket)

  @doc "Receive one full message; returns {:text, str} | {:binary, bin}."
  def recv(c, timeout \\ 2000) do
    {opcode, payload, buffer} = read_frame(c.socket, c.buffer, timeout)
    kind = if opcode == 0x2, do: :binary, else: :text
    {%{c | buffer: buffer}, kind, payload}
  end

  @doc "Like recv/2 but returns :timeout instead of raising when nothing arrives."
  def recv_safe(c, timeout) do
    {c, kind, payload} = recv(c, timeout)
    {:ok, c, kind, payload}
  catch
    :error, _ -> :timeout
  end

  @doc "Collect all frames until a recv times out. Returns {client, [{kind, payload}]}."
  def drain(c, timeout \\ 400, acc \\ []) do
    case recv_safe(c, timeout) do
      {:ok, c, kind, payload} -> drain(c, timeout, [{kind, payload} | acc])
      :timeout -> {c, Enum.reverse(acc)}
    end
  end

  @doc "Collect text lines until `pred.(line)` is true or timeout; returns {client, lines}."
  def recv_lines_until(c, pred, timeout \\ 2000, acc \\ []) do
    {c, :text, payload} = recv(c, timeout)

    lines =
      payload |> String.split(~r/\r?\n/) |> Enum.reject(&(&1 == ""))

    acc = acc ++ lines

    if Enum.any?(lines, pred) do
      {c, acc}
    else
      recv_lines_until(c, pred, timeout, acc)
    end
  end

  # ----- framing -----

  defp frame(opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    masked = apply_mask(payload, mask)
    len = byte_size(payload)

    len_bytes =
      cond do
        len < 126 -> <<0x80 ||| len::8>>
        len < 65_536 -> <<0x80 ||| 126::8, len::16>>
        true -> <<0x80 ||| 127::8, len::64>>
      end

    <<0x80 ||| opcode::8>> <> len_bytes <> mask <> masked
  end

  defp read_frame(socket, buffer, timeout) do
    {b0, buffer} = need(socket, buffer, 1, timeout)
    <<_fin::1, _rsv::3, opcode::4>> = b0
    {b1, buffer} = need(socket, buffer, 1, timeout)
    <<mask_bit::1, len0::7>> = b1

    {len, buffer} =
      case len0 do
        126 -> {bin, buffer} = need(socket, buffer, 2, timeout); <<l::16>> = bin; {l, buffer}
        127 -> {bin, buffer} = need(socket, buffer, 8, timeout); <<l::64>> = bin; {l, buffer}
        l -> {l, buffer}
      end

    {mask, buffer} = if mask_bit == 1, do: need(socket, buffer, 4, timeout), else: {<<>>, buffer}
    {payload, buffer} = need(socket, buffer, len, timeout)
    payload = if mask_bit == 1, do: apply_mask(payload, mask), else: payload
    {opcode, payload, buffer}
  end

  defp need(_socket, buffer, n, _timeout) when byte_size(buffer) >= n do
    <<chunk::binary-size(n), rest::binary>> = buffer
    {chunk, rest}
  end

  defp need(socket, buffer, n, timeout) do
    {:ok, more} = :gen_tcp.recv(socket, 0, timeout)
    need(socket, buffer <> more, n, timeout)
  end

  defp apply_mask(data, mask) when byte_size(mask) == 4 do
    apply_mask(data, mask, 0, <<>>)
  end

  defp apply_mask(data, _), do: data

  defp apply_mask(<<>>, _mask, _i, acc), do: acc

  defp apply_mask(<<b, rest::binary>>, mask, i, acc) do
    m = :binary.at(mask, rem(i, 4))
    apply_mask(rest, mask, i + 1, <<acc::binary, bxor(b, m)>>)
  end

  defp read_until_headers(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {pos, 4} ->
        <<headers::binary-size(pos), _::binary-size(4), rest::binary>> = acc
        {headers, rest}

      :nomatch ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 2000)
        read_until_headers(socket, acc <> more)
    end
  end
end
