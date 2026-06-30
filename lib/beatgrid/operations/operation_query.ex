defmodule Beatgrid.Operations.OperationQuery do
  @moduledoc "All reads for `Beatgrid.Operations.Operation`."

  import Ecto.Query

  alias Beatgrid.Operations.Operation
  alias Beatgrid.Repo

  @type list_opt ::
          {:batch_id, Ecto.UUID.t()}
          | {:track_id, Ecto.UUID.t()}
          | {:status, atom()}
          | {:kind, atom()}
          | {:limit, pos_integer()}
          | {:preload, list()}

  @spec list_by([list_opt()]) :: [Operation.t()]
  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, desc: :inserted_at)
    |> Enum.reduce(Operation, &reduce_opt/2)
    |> Repo.all()
  end

  @spec count([list_opt()]) :: non_neg_integer()
  def count(opts \\ []) do
    opts
    |> Enum.reduce(Operation, &reduce_opt/2)
    |> Repo.aggregate(:count, :id)
  end

  defp reduce_opt({:batch_id, batch_id}, q), do: where(q, [o], o.batch_id == ^batch_id)
  defp reduce_opt({:track_id, track_id}, q), do: where(q, [o], o.track_id == ^track_id)
  defp reduce_opt({:status, status}, q), do: where(q, [o], o.status == ^status)
  defp reduce_opt({:kind, kind}, q), do: where(q, [o], o.kind == ^kind)
  defp reduce_opt({:limit, n}, q), do: limit(q, ^n)
  defp reduce_opt({:preload, preloads}, q), do: preload(q, ^preloads)
  defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)
end
