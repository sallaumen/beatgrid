defmodule Beatgrid.Workers.MoveBatchWorker do
  @moduledoc """
  Moves a selection of tracks to a genre folder on disk in the background, so a
  big batch is durable (survives a closed tab, shows in `/jobs`) instead of
  freezing the Biblioteca. Broadcasts `{:tracks_moved, result}` on the library
  topic when done, which pops the Desfazer toast.

  `max_attempts: 1` — move_many reports per-item moved/failed counts and never
  aborts on one failure; an automatic whole-batch retry would re-move what
  already moved.
  """
  use Oban.Worker,
    queue: :scan,
    max_attempts: 1,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  alias Beatgrid.Library

  @spec enqueue([Ecto.UUID.t()], String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(ids, folder_key) when is_list(ids),
    do: %{ids: ids, folder: folder_key} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ids" => ids, "folder" => folder}}) do
    result = Library.move_many(ids, folder)
    Library.broadcast_moved(result)
    :ok
  end
end
