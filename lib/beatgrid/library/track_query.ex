defmodule Beatgrid.Library.TrackQuery do
  @moduledoc "All reads for `Beatgrid.Library.Track`."

  import Ecto.Query

  alias Beatgrid.Library.Track
  alias Beatgrid.Repo

  @type list_opt ::
          {:status, atom()}
          | {:genre_folder, String.t() | nil}
          | {:with_quality_issues, boolean()}
          | {:order_by, term()}

  @spec list_by([list_opt()]) :: [Track.t()]
  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, asc: :rel_path)
    |> Enum.reduce(Track, &reduce_opt/2)
    |> Repo.all()
  end

  @spec get_by_path(String.t()) :: Track.t() | nil
  def get_by_path(rel_path), do: Repo.get_by(Track, rel_path: rel_path)

  @spec count([list_opt()]) :: non_neg_integer()
  def count(opts \\ []) do
    opts
    |> Enum.reduce(Track, &reduce_opt/2)
    |> Repo.aggregate(:count, :id)
  end

  defp reduce_opt({:status, status}, q), do: where(q, [t], t.status == ^status)
  defp reduce_opt({:genre_folder, nil}, q), do: where(q, [t], is_nil(t.genre_folder))
  defp reduce_opt({:genre_folder, folder}, q), do: where(q, [t], t.genre_folder == ^folder)
  defp reduce_opt({:with_quality_issues, true}, q), do: where(q, [t], t.quality_issues != ^[])
  defp reduce_opt({:with_quality_issues, false}, q), do: where(q, [t], t.quality_issues == ^[])
  defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)
end
