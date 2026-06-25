defmodule Beatgrid.Workers.ResolveSongWorker do
  @moduledoc """
  Resolves one track against Soundcharts. Queued on `:soundcharts` (local_limit 1
  so we never run concurrent quota-spending calls). Unique per track so a track
  is not queued twice. Snoozes when the budget floor is hit instead of failing.
  """
  use Oban.Worker,
    queue: :soundcharts,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:track_id]]

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Soundcharts

  @snooze_seconds 3600

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"track_id" => track_id}}) do
    case Tracks.get(track_id) do
      nil -> {:cancel, :track_not_found}
      track -> resolve(track)
    end
  end

  defp resolve(track) do
    case Soundcharts.resolve_track(track) do
      # covers both {:ok, %Song{}} and {:ok, :already_linked}
      {:ok, _} -> :ok
      {:error, :budget_exhausted} -> {:snooze, @snooze_seconds}
      {:error, :no_match} -> {:cancel, :no_match}
      {:error, reason} -> {:error, reason}
    end
  end
end
