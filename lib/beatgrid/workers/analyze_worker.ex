defmodule Beatgrid.Workers.AnalyzeWorker do
  @moduledoc """
  Runs local audio analysis (BPM + key) for one track in the background, then
  broadcasts a progress tick. Queued on `:analysis` (small local_limit — librosa
  is CPU-heavy), unique per track so a track isn't queued twice.
  """
  use Oban.Worker,
    queue: :analysis,
    max_attempts: 2,
    unique: [period: 300, fields: [:args], keys: [:track_id]]

  alias Beatgrid.Analysis
  alias Beatgrid.Library.Tracks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"track_id" => track_id}}) do
    case Tracks.get(track_id) do
      nil ->
        {:cancel, :track_not_found}

      track ->
        result = Analysis.analyze_track(track)
        Analysis.broadcast_tick()

        case result do
          {:ok, _track} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
