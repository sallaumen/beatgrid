defmodule Beatgrid.Repertoire.RecommendationQuery do
  @moduledoc "Reads for `Beatgrid.Repertoire.Recommendation`."
  import Ecto.Query
  alias Beatgrid.Repertoire.Recommendation
  alias Beatgrid.Repo

  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, desc: :inserted_at)
    |> Enum.reduce(Recommendation, &reduce_opt/2)
    |> Repo.all()
  end

  def count(opts \\ []) do
    opts |> Enum.reduce(Recommendation, &reduce_opt/2) |> Repo.aggregate(:count, :id)
  end

  defp reduce_opt({:genre_folder, k}, q), do: where(q, [r], r.genre_folder == ^k)
  defp reduce_opt({:track_id, id}, q), do: where(q, [r], r.track_id == ^id)
  defp reduce_opt({:source, s}, q), do: where(q, [r], r.source == ^s)
  defp reduce_opt({:status, s}, q), do: where(q, [r], r.status == ^s)
  defp reduce_opt({:statuses, ss}, q), do: where(q, [r], r.status in ^ss)
  defp reduce_opt({:artist, a}, q), do: where(q, [r], r.artist == ^a)
  defp reduce_opt({:song, s}, q), do: where(q, [r], r.song == ^s)
  defp reduce_opt({:preload, p}, q), do: preload(q, ^p)
  defp reduce_opt({:order_by, o}, q), do: order_by(q, ^o)

  defp reduce_opt({opt, value}, _q),
    do: raise(Beatgrid.Query.FilterError, field: opt, value: value)
end
