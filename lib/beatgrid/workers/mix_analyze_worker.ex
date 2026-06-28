defmodule Beatgrid.Workers.MixAnalyzeWorker do
  @moduledoc """
  Analyzes a downloaded mix: parses the description tracklist (AI), determines
  segment boundaries (description timestamps when present, else audio detection),
  analyzes each segment's BPM/Camelot (librosa), matches names to the library, and
  persists the segments. Marks the mix `:ready` and schedules a cancelable 24h audio
  cleanup. Quota-free (local librosa + Claude-Max).
  """
  use Oban.Worker, queue: :mixes, max_attempts: 3

  alias Beatgrid.Mixes
  alias Beatgrid.Mixes.TracklistAI
  alias Beatgrid.Soundcharts.Camelot
  alias Beatgrid.Workers.MixCleanupWorker

  @segmenter Application.compile_env(
               :beatgrid,
               [Beatgrid.Audio.SetSegmenter, :adapter],
               Beatgrid.Audio.SetSegmenter.LibrosaCli
             )

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mix_id" => mix_id}}) do
    case Mixes.get_mix(mix_id) do
      nil -> :ok
      %{audio_path: nil} = mix -> fail(mix, :no_audio)
      mix -> run(mix)
    end
  end

  defp run(mix) do
    tracklist = TracklistAI.parse(mix.description)
    boundaries = boundaries_from(tracklist)

    case @segmenter.analyze(mix.audio_path, boundaries) do
      {:ok, raw_segments} ->
        segments = build_segments(raw_segments, tracklist)
        {:ok, _n} = Mixes.replace_segments(mix, segments)

        {:ok, _} =
          Mixes.set_status(mix, :ready, %{
            analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        schedule_cleanup(mix)
        Mixes.broadcast(%{mix_id: mix.id, status: :ready})
        :ok

      {:error, reason} ->
        fail(mix, reason)
    end
  end

  # Path A: tracklist has timestamps → use them. Else [] → segmenter auto-detects.
  defp boundaries_from(tracklist) do
    tracklist
    |> Enum.map(& &1.start_seconds)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(&1 * 1000))
    |> Enum.sort()
  end

  # Zip segment analysis with names by ORDER (Path A/B). Extra audio segments beyond
  # the tracklist stay unnamed (name_source :audio); a tracklist longer than the
  # detected segments simply runs out of segments to attach to.
  defp build_segments(raw_segments, tracklist) do
    raw_segments
    |> Enum.with_index()
    |> Enum.map(fn {seg, i} ->
      entry = Enum.at(tracklist, i)
      camelot = Camelot.from_key(seg.key, seg.mode)
      match = entry && Mixes.match_track(entry.artist, entry.title)

      %{
        position: i,
        start_ms: seg.start_ms,
        end_ms: seg.end_ms,
        bpm_detected: seg.bpm,
        camelot_detected: camelot,
        artist: entry && entry.artist,
        title: entry && entry.title,
        name_source: if(entry && (entry.artist || entry.title), do: :description, else: :audio),
        matched_track_id: match && match.track_id,
        match_confidence: match && match.confidence
      }
    end)
  end

  defp schedule_cleanup(mix) do
    {:ok, job} =
      Oban.insert(MixCleanupWorker.new(%{mix_id: mix.id}, schedule_in: 86_400))

    Mixes.update_mix(mix, %{cleanup_job_id: job.id})
  end

  defp fail(mix, reason) do
    Mixes.set_status(mix, :failed, %{error: inspect(reason)})
    Mixes.broadcast(%{mix_id: mix.id, status: :failed})
    {:error, reason}
  end
end
