defmodule Chronodivexd.Router do
  @moduledoc """
  Single Plug entry point for the Bandit listener:

    * `POST /register`  — account signup (JSON `{user,pass,locale}`)
    * `GET  /`          — WebSocket upgrade → WOL lobby (`Chronodivexd.Wol.Conn`)
    * `GET  /gserv`     — WebSocket upgrade → gserv relay (`Chronodivexd.Gserv.Conn`)

  CORS is permissive because the client page is served from a different origin
  (the static mirror on :8000) yet `fetch`es `/register` here.
  """
  use Plug.Router
  require Logger

  plug :match
  plug :dispatch

  # --- WebSocket endpoints -------------------------------------------------

  get "/" do
    if websocket?(conn) do
      conn
      |> WebSockAdapter.upgrade(Chronodivexd.Wol.Conn, %{}, timeout: 60_000)
      |> halt()
    else
      send_resp(conn, 200, "chronodivexd: WOL endpoint (connect via WebSocket)\n")
    end
  end

  get "/gserv" do
    if websocket?(conn) do
      conn
      |> WebSockAdapter.upgrade(Chronodivexd.Gserv.Conn, %{}, timeout: 60_000)
      |> halt()
    else
      send_resp(conn, 200, "chronodivexd: gserv endpoint (connect via WebSocket)\n")
    end
  end

  # --- Registration --------------------------------------------------------

  options "/register" do
    conn |> cors() |> send_resp(204, "")
  end

  post "/register" do
    # Registration is a tiny JSON body; cap the read so a giant body can't be
    # buffered into memory.
    {body, conn} =
      case read_body(conn, length: 8_192) do
        {:ok, body, conn} -> {body, conn}
        {:more, _partial, conn} -> {:too_large, conn}
        {:error, _reason} -> {:too_large, conn}
      end

    conn = cors(conn)

    case body != :too_large && Jason.decode(body) do
      {:ok, %{"user" => user, "pass" => pass} = params} ->
        locale = Map.get(params, "locale")

        case Chronodivexd.Accounts.create(user, pass, locale) do
          :ok ->
            Logger.info("Registered account #{inspect(user)}")
            json(conn, 200, %{})

          {:error, message} ->
            json(conn, 200, %{error: message})
        end

      _ ->
        json(conn, 200, %{error: "Invalid request."})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- helpers -------------------------------------------------------------

  defp websocket?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type")
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
