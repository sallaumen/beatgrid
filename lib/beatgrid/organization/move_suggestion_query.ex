defmodule Beatgrid.Organization.MoveSuggestionQuery do
  @moduledoc "All reads for `Beatgrid.Organization.MoveSuggestion`."

  import Ecto.Query

  alias Beatgrid.Organization.MoveSuggestion
  alias Beatgrid.Repo

  @type list_opt ::
          {:status, atom()}
          | {:statuses, [atom()]}
          | {:source, atom()}
          | {:to_genre_folder, String.t()}
          | {:batch_id, Ecto.UUID.t()}
          | {:preload, list()}

  @spec list_by([list_opt()]) :: [MoveSuggestion.t()]
  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, asc: :inserted_at)
    |> Enum.reduce(MoveSuggestion, &reduce_opt/2)
    |> Repo.all()
  end

  @spec count([list_opt()]) :: non_neg_integer()
  def count(opts \\ []) do
    opts
    |> Enum.reduce(MoveSuggestion, &reduce_opt/2)
    |> Repo.aggregate(:count, :id)
  end

  defp reduce_opt({:status, status}, q), do: where(q, [s], s.status == ^status)
  defp reduce_opt({:statuses, statuses}, q), do: where(q, [s], s.status in ^statuses)
  defp reduce_opt({:source, source}, q), do: where(q, [s], s.source == ^source)

  defp reduce_opt({:to_genre_folder, folder}, q),
    do: where(q, [s], s.to_genre_folder == ^folder)

  defp reduce_opt({:batch_id, batch_id}, q), do: where(q, [s], s.batch_id == ^batch_id)
  defp reduce_opt({:preload, preloads}, q), do: preload(q, ^preloads)
  defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)
end
