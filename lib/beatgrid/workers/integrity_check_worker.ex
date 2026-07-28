defmodule Beatgrid.Workers.IntegrityCheckWorker do
  @moduledoc """
  Checks one track's file playability for the Resgate census (full ffmpeg
  decode). Queued on `:analysis`, unique per track.
  """
  use Oban.Worker,
    queue: :analysis,
    max_attempts: 2,
    unique: [period: 300, keys: [:track_id]]

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Rescue

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"track_id" => track_id}}) do
    case Tracks.get(track_id) do
      nil -> :ok
      track -> with {:ok, _updated} <- Rescue.check(track), do: :ok
    end
  end

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(track_id), do: %{track_id: track_id} |> new() |> Oban.insert()
end
