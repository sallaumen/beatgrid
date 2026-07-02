defmodule Beatgrid.Dashboard do
  @moduledoc """
  Facade for the dashboard: the LiveView renders and translates UI events; the
  operational knowledge lives behind this small interface, split by direction —
  `Beatgrid.Dashboard.ReadModel` (snapshot, gaps, PubSub-driven patches) and
  `Beatgrid.Dashboard.Commands` (panel actions).
  """

  alias Beatgrid.Dashboard.{Commands, ReadModel}

  @spec subscribe() :: :ok
  defdelegate subscribe, to: ReadModel

  @spec snapshot(String.t() | nil) :: map()
  defdelegate snapshot(selected_folder \\ nil), to: ReadModel

  @spec gaps(String.t() | nil) :: map()
  defdelegate gaps(folder), to: ReadModel

  @spec refresh(term()) :: {:ok, map()} | :ignore
  defdelegate refresh(event), to: ReadModel

  @spec enrich_summary(map()) :: String.t()
  defdelegate enrich_summary(payload), to: ReadModel

  @spec run(term(), keyword()) :: {:ok, map()} | {:flash, atom(), String.t()}
  defdelegate run(command, opts \\ []), to: Commands
end
