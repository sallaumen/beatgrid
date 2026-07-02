defmodule Beatgrid.Workers.MarkerAnalyzeWorker do
  @moduledoc """
  Detects cue markers (intro / outro / sections) for one track via audio analysis,
  in the background. Queued on `:analysis` (librosa is CPU-heavy), unique per track.
  `Markers.detect/1` persists the auto markers and broadcasts, so subscribed pages
  refresh live when it finishes.
  """
  use Oban.Worker,
    queue: :analysis,
    max_attempts: 2,
    unique: [period: 300, fields: [:args], keys: [:track_id]]

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Markers

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(track_id), do: %{track_id: track_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"track_id" => track_id}}) do
    case Tracks.get(track_id) do
      nil ->
        {:cancel, :track_not_found}

      track ->
        case Markers.detect(track) do
          {:ok, _track} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
