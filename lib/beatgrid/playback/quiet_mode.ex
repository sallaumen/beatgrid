defmodule Beatgrid.Playback.QuietMode do
  @moduledoc """
  Pauses background work while a set is actively playing.

  Each player holds a claim while it needs silence. Closing a tab or pausing a
  preview releases only its claim. Work resumes when the last player releases
  it or its monitored process exits.

  This is intentionally small and process-local: Beatgrid is a single-user local
  app, and audio smoothness matters more than continuing background throughput
  during a set.
  """
  use GenServer

  @type scope :: :all | [atom()]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec activate(GenServer.server()) :: :ok | {:error, term()}
  def activate(server \\ __MODULE__), do: GenServer.call(server, {:activate, self()})

  @spec deactivate(GenServer.server()) :: :ok | {:error, term()}
  def deactivate(server \\ __MODULE__), do: GenServer.call(server, {:deactivate, self()})

  @spec active?(GenServer.server()) :: boolean()
  def active?(server \\ __MODULE__), do: GenServer.call(server, :active?)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owners: %{},
       controller: Keyword.get(opts, :controller),
       scope: Keyword.get(opts, :scope)
     }}
  end

  @impl GenServer
  def handle_call({:activate, owner}, _from, state) do
    result = if map_size(state.owners) == 0, do: controller(state).pause(scope(state)), else: :ok
    owners = Map.put_new_lazy(state.owners, owner, fn -> Process.monitor(owner) end)
    {:reply, result, %{state | owners: owners}}
  end

  def handle_call({:deactivate, owner}, _from, state) do
    {result, state} = release(state, owner)
    {:reply, result, state}
  end

  def handle_call(:active?, _from, state), do: {:reply, map_size(state.owners) > 0, state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{owners: owners} = state)
      when is_map_key(owners, pid) and :erlang.map_get(pid, owners) == ref do
    {_result, state} = release(state, pid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp release(state, owner) do
    case Map.pop(state.owners, owner) do
      {nil, _owners} ->
        {:ok, state}

      {ref, owners} ->
        Process.demonitor(ref, [:flush])
        result = if map_size(owners) == 0, do: controller(state).resume(scope(state)), else: :ok
        {result, %{state | owners: owners}}
    end
  end

  defp controller(%{controller: controller}) when is_atom(controller) and not is_nil(controller),
    do: controller

  defp controller(_state) do
    :beatgrid
    |> Application.get_env(__MODULE__)
    |> Kernel.||([])
    |> Keyword.get(:controller, __MODULE__.ObanController)
  end

  defp scope(%{scope: scope}) when not is_nil(scope), do: scope

  defp scope(_state) do
    :beatgrid
    |> Application.get_env(__MODULE__)
    |> Kernel.||([])
    |> Keyword.get(:scope, :all)
  end
end
