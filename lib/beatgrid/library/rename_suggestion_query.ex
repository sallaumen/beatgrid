defmodule Beatgrid.Library.RenameSuggestionQuery do
  @moduledoc "All reads for `Beatgrid.Library.RenameSuggestion`."

  import Ecto.Query

  alias Beatgrid.Library.RenameSuggestion
  alias Beatgrid.Repo

  @type list_opt ::
          {:status, atom()}
          | {:confidence, atom()}
          | {:order_by, term()}

  @spec list_by([list_opt()]) :: [RenameSuggestion.t()]
  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, asc: :from_rel_path)
    |> Enum.reduce(RenameSuggestion, &reduce_opt/2)
    |> Repo.all()
  end

  @spec count([list_opt()]) :: non_neg_integer()
  def count(opts \\ []) do
    opts
    |> Enum.reduce(RenameSuggestion, &reduce_opt/2)
    |> Repo.aggregate(:count, :id)
  end

  defp reduce_opt({:status, status}, q), do: where(q, [s], s.status == ^status)
  defp reduce_opt({:confidence, confidence}, q), do: where(q, [s], s.confidence == ^confidence)
  defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)
end
