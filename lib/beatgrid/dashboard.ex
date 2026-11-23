defmodule Beatgrid.Dashboard do
  @moduledoc """
  Facade for the repertoire overview and library maintenance. The read model
  supplies page snapshots and progress updates. Commands dispatch page actions.
  """

  alias Beatgrid.Dashboard.{Commands, ReadModel}

  @spec subscribe() :: :ok
  defdelegate subscribe, to: ReadModel

  @spec subscribe_maintenance() :: :ok
  defdelegate subscribe_maintenance, to: ReadModel

  @spec snapshot(String.t() | nil) :: map()
  defdelegate snapshot(selected_folder \\ nil), to: ReadModel

  @spec maintenance_snapshot() :: map()
  defdelegate maintenance_snapshot, to: ReadModel

  @spec gaps(String.t() | nil) :: map()
  defdelegate gaps(folder), to: ReadModel

  @spec refresh(term()) :: {:ok, map()} | :ignore
  defdelegate refresh(event), to: ReadModel

  @spec enrich_summary(map()) :: String.t()
  defdelegate enrich_summary(payload), to: ReadModel

  @spec run(term(), keyword()) :: {:ok, map()} | {:flash, atom(), String.t()}
  defdelegate run(command, opts \\ []), to: Commands
end
