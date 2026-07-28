defmodule Beatgrid.Rescue.RescueQuery do
  @moduledoc "Read side of the Resgate census: integrity counts and damaged rows."

  import Ecto.Query

  alias Beatgrid.Library.Track
  alias Beatgrid.Repo

  @doc "Present-track counts by integrity status (absent statuses omitted)."
  @spec integrity_counts() :: %{atom() => non_neg_integer()}
  def integrity_counts do
    Track
    |> where([t], t.status == :present)
    |> group_by([t], t.integrity_status)
    |> select([t], {t.integrity_status, count()})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Present tracks whose file is gone or no longer decodes, worst first."
  @spec damaged() :: [Track.t()]
  def damaged do
    Track
    |> where([t], t.status == :present)
    |> where([t], t.integrity_status in [:missing_file, :corrupt])
    |> order_by([t], asc: t.integrity_status, asc: t.rel_path)
    |> Repo.all()
  end
end
