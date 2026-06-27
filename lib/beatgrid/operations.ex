defmodule Beatgrid.Operations do
  @moduledoc """
  The unified, persistent log of disk mutations (rename / move / tag) applied
  through the review surface. Every apply records an operation; `undo_batch/1`
  reverts an entire apply-batch by delegating to the owning context's `undo/1`,
  which keeps the suggestion status consistent with what the UI shows. This log
  is what the "Desfazer" action targets, and it survives the toast.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Operations.{Operation, OperationQuery}
  alias Beatgrid.{Organization, Tagging}
  alias Beatgrid.Repo

  @spec record(map()) :: {:ok, Operation.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs), do: %Operation{} |> Operation.changeset(attrs) |> Repo.insert()

  @spec list_by(keyword()) :: [Operation.t()]
  def list_by(opts \\ []), do: OperationQuery.list_by(opts)

  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []), do: OperationQuery.count(opts)

  @doc """
  Reverts every still-applied operation in a batch, newest first, delegating to
  the owning context so the suggestion is flipped back to `:undone` too. One
  failure does not abort the rest. Returns the undone/failed counts.
  """
  @spec undo_batch(Ecto.UUID.t()) ::
          {:ok, %{undone: non_neg_integer(), failed: non_neg_integer()}}
  def undo_batch(batch_id) do
    results =
      [batch_id: batch_id, status: :applied]
      |> OperationQuery.list_by()
      |> Enum.map(&undo_one/1)

    {:ok,
     %{
       undone: Enum.count(results, &(&1 == :undone)),
       failed: Enum.count(results, &(&1 == :failed))
     }}
  end

  defp undo_one(%Operation{kind: :rename, suggestion_id: sid} = op),
    do: do_undo(op, NameSync.get(sid), &NameSync.undo/1)

  # A manual move (no backing suggestion) is reverted by relocating the file back
  # to `op.from`, into whatever folder that path belongs to.
  defp undo_one(%Operation{kind: :move, suggestion_id: nil} = op) do
    case Tracks.get(op.track_id) do
      nil ->
        mark_failed(op, :track_not_found)

      track ->
        do_undo(op, track, fn t ->
          Library.relocate(t, op.from, Library.genre_folder_for_rel(op.from))
        end)
    end
  end

  defp undo_one(%Operation{kind: :move, suggestion_id: sid} = op),
    do: do_undo(op, Organization.get(sid), &Organization.undo/1)

  defp undo_one(%Operation{kind: :tag, from: from} = op) do
    case Tracks.get(op.track_id) do
      nil -> mark_failed(op, :track_not_found)
      track -> do_undo(op, track, &Tagging.restore_genre(&1, from))
    end
  end

  defp do_undo(op, nil, _undo), do: mark_failed(op, :suggestion_not_found)

  defp do_undo(op, suggestion, undo) do
    case undo.(suggestion) do
      {:ok, _} -> mark_undone(op)
      error -> mark_failed(op, error)
    end
  end

  defp mark_undone(op) do
    {:ok, _} = op |> Operation.changeset(%{status: :undone}) |> Repo.update()
    :undone
  end

  defp mark_failed(op, error) do
    {:ok, _} =
      op |> Operation.changeset(%{status: :failed, error: inspect(error)}) |> Repo.update()

    :failed
  end
end
