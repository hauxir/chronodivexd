defmodule Chronodivexd.Gserv.Registry do
  @moduledoc """
  Maps a gameId → its `Chronodivexd.Gserv.Instance` pid. The host creates the
  instance on `create`; joiners look it up (retrying)
  on `join`.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Create (or fetch) the instance for game_id, owned by the host."
  def create(game_id, opts), do: GenServer.call(__MODULE__, {:create, game_id, opts})

  @doc "Look up an existing instance pid, or :error."
  def lookup(game_id), do: GenServer.call(__MODULE__, {:lookup, game_id})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:create, game_id, opts}, _from, st) do
    case Map.get(st, game_id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:reply, {:error, :exists}, st}, else: spawn_instance(game_id, opts, st)

      _ ->
        spawn_instance(game_id, opts, st)
    end
  end

  def handle_call({:lookup, game_id}, _from, st) do
    case Map.get(st, game_id) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: {:reply, {:ok, pid}, st}, else: {:reply, :error, Map.delete(st, game_id)}
      _ -> {:reply, :error, st}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, st) do
    {:noreply, st |> Enum.reject(fn {_id, p} -> p == pid end) |> Map.new()}
  end

  defp spawn_instance(game_id, opts, st) do
    {:ok, pid} = Chronodivexd.Gserv.Instance.start_link(game_id, opts)
    Process.monitor(pid)
    {:reply, {:ok, pid}, Map.put(st, game_id, pid)}
  end
end
