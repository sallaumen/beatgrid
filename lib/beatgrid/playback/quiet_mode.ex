defmodule Beatgrid.Playback.QuietMode do
  @moduledoc """
  Pauses background work while a set is actively playing.

  The activator (the console LiveView) is monitored: if it dies without
  deactivating — a crash, a killed tab, anything that skips `terminate` —
  background work resumes on its own instead of staying paused forever.

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
  def deactivate(server \\ __MODULE__), do: GenServer.call(server, :deactivate)

  @spec active?(GenServer.server()) :: boolean()
  def active?(server \\ __MODULE__), do: GenServer.call(server, :active?)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       active?: false,
       owner_ref: nil,
       controller: Keyword.get(opts, :controller),
       scope: Keyword.get(opts, :scope)
     }}
  end

  @impl GenServer
  def handle_call({:activate, owner}, _from, %{active?: false} = state) do
    ref = Process.monitor(owner)
    {:reply, controller(state).pause(scope(state)), %{state | active?: true, owner_ref: ref}}
  end

  def handle_call({:activate, owner}, _from, state) do
    Process.demonitor(state.owner_ref, [:flush])
    {:reply, :ok, %{state | owner_ref: Process.monitor(owner)}}
  end

  def handle_call(:deactivate, _from, %{active?: true} = state) do
    Process.demonitor(state.owner_ref, [:flush])
    {:reply, controller(state).resume(scope(state)), %{state | active?: false, owner_ref: nil}}
  end

  def handle_call(:deactivate, _from, state), do: {:reply, :ok, state}

  def handle_call(:active?, _from, state), do: {:reply, state.active?, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    controller(state).resume(scope(state))
    {:noreply, %{state | active?: false, owner_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
