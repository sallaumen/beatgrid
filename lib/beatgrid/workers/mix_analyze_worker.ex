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
    boundaries = boundaries_for(mix, tracklist)

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

  defp boundaries_for(mix, tracklist) do
    case boundaries_from(tracklist) do
      [] -> chapter_boundaries(mix)
      bs -> bs
    end
  end

  defp chapter_boundaries(%{chapters_role: :tracks, chapters: chapters}) when is_list(chapters) do
    chapters
    |> Enum.map(&Map.get(&1, "start_ms"))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp chapter_boundaries(_mix), do: []

  # Path A: tracklist has timestamps → use them. Else [] → segmenter auto-detects.
  defp boundaries_from(tracklist) do
    tracklist
    |> Enum.map(& &1.start_seconds)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(&1 * 1000))
    |> Enum.sort()
  end

  defp build_segments(raw_segments, tracklist) do
    # With timestamps (Path A), names align to segments by START TIME — the
    # segmenter may prepend an unnamed intro segment at 0, so a plain zip-by-index
    # would shift every name down by one. Without timestamps (Path B), fall back to
    # zip-by-order.
    by_start =
      for e <- tracklist, e.start_seconds != nil, into: %{}, do: {e.start_seconds * 1000, e}

    raw_segments
    |> Enum.with_index()
    |> Enum.map(fn {seg, i} ->
      entry =
        if map_size(by_start) > 0,
          do: Map.get(by_start, seg.start_ms),
          else: Enum.at(tracklist, i)

      build_segment(seg, i, entry)
    end)
  end

  defp build_segment(seg, i, entry) do
    camelot = Camelot.from_key(seg.key, seg.mode)
    match = entry && Mixes.match_track(entry.artist, entry.title)
    named? = entry && (entry.artist || entry.title)

    %{
      position: i,
      start_ms: seg.start_ms,
      end_ms: seg.end_ms,
      bpm_detected: seg.bpm,
      camelot_detected: camelot,
      artist: entry && entry.artist,
      title: entry && entry.title,
      name_source: if(named?, do: :description, else: :audio),
      matched_track_id: match && match.track_id,
      match_confidence: match && match.confidence
    }
  end

  defp schedule_cleanup(mix) do
    {:ok, job} =
      Oban.insert(MixCleanupWorker.new(%{mix_id: mix.id}, schedule_in: 86_400))

    {:ok, _} = Mixes.update_mix(mix, %{cleanup_job_id: job.id})
  end

  defp fail(mix, reason) do
    Mixes.set_status(mix, :failed, %{error: inspect(reason)})
    Mixes.broadcast(%{mix_id: mix.id, status: :failed})
    {:error, reason}
  end
end
