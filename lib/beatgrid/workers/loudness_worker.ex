defmodule Beatgrid.Workers.LoudnessWorker do
  @moduledoc """
  Measures one track's loudness (LUFS + true peak) in the background, broadcasting a
  progress tick so the Painel updates. Offline + quota-free; deduped per track while
  a job is in flight. A measurement failure (missing file, silence) retries then
  discards — the track stays unmeasured and can be re-run from the Painel.
  """
  use Oban.Worker,
    queue: :analysis,
    max_attempts: 3,
    unique: [period: 30, keys: [:track_id]]

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Loudness

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"track_id" => id}}) do
    case Tracks.get(id) do
      nil ->
        :ok

      track ->
        with {:ok, _track} <- Loudness.measure_track(track) do
          Loudness.broadcast_tick()
          :ok
        end
    end
  end
end
