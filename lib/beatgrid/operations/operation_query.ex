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

  # What "Aplicar no disco" writes. Gain lives in the Painel with its own undo.
  @review_kinds ~w(rename move tag quarantine)a

  @spec list_by([list_opt()]) :: [Operation.t()]
  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, desc: :inserted_at)
    |> Enum.reduce(Operation, &reduce_opt/2)
    |> Repo.all()
  end

  @doc """
  The most recent disk-writing batches, newest first, with what a review screen
  needs to offer an undo: how many rows the batch moved and whether any of them
  are still applied. Gain batches are excluded — the Painel owns those and
  restores them from its own backups.
  """
  @spec recent_batches(keyword()) :: [
          %{
            batch_id: Ecto.UUID.t(),
            count: non_neg_integer(),
            at: DateTime.t(),
            undoable?: boolean()
          }
        ]
  def recent_batches(opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    Operation
    |> where([o], o.kind in ^@review_kinds)
    |> group_by([o], o.batch_id)
    |> select([o], %{
      batch_id: o.batch_id,
      count: count(o.id),
      at: max(o.inserted_at),
      applied: filter(count(o.id), o.status == :applied)
    })
    # Timestamps are second-precision, so two batches applied in the same second
    # tie. batch_id is a UUID v7 — time-ordered by construction — so it breaks
    # the tie in the same direction instead of leaving the order to the planner.
    |> order_by([o], desc: max(o.inserted_at), desc: o.batch_id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn row ->
      row |> Map.delete(:applied) |> Map.put(:undoable?, row.applied > 0)
    end)
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

  defp reduce_opt({opt, value}, _q),
    do: raise(Beatgrid.Query.FilterError, field: opt, value: value)
end
