defmodule Beatgrid.Playback.QuietMode do
  @moduledoc """
  Pauses background work while a set is actively playing.

  This is intentionally small and process-local: Beatgrid is a single-user local
  app, and audio smoothness matters more than continuing background throughput
  during a set.
  """
  use Agent

  @type scope :: :all | [atom()]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: false,
      controller: Keyword.get(opts, :controller),
      scope: Keyword.get(opts, :scope)
    }

    Agent.start_link(fn -> state end, name: name)
  end

  @spec activate(GenServer.server()) :: :ok | {:error, term()}
  def activate(server \\ __MODULE__) do
    case transition(server, true) do
      {:changed, state} -> controller(state).pause(scope(state))
      :unchanged -> :ok
    end
  end

  @spec deactivate(GenServer.server()) :: :ok | {:error, term()}
  def deactivate(server \\ __MODULE__) do
    case transition(server, false) do
      {:changed, state} -> controller(state).resume(scope(state))
      :unchanged -> :ok
    end
  end

  @spec active?(GenServer.server()) :: boolean()
  def active?(server \\ __MODULE__), do: Agent.get(server, & &1.active?)

  defp transition(server, active?) do
    Agent.get_and_update(server, fn state ->
      if state.active? == active? do
        {:unchanged, state}
      else
        {{:changed, state}, %{state | active?: active?}}
      end
    end)
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
