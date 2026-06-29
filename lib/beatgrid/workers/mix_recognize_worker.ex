defmodule Beatgrid.Workers.MixRecognizeWorker do
  @moduledoc "Identifies unnamed segments of a mix via the Recognition port (AudD). Button-triggered, paid."
  use Oban.Worker,
    queue: :mixes,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:mix_id, :segment_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Beatgrid.{Integrations, Mixes, Repo}
  alias Beatgrid.Mixes.Segment

  @recognizer Application.compile_env(:beatgrid, [Beatgrid.Recognition, :adapter], Beatgrid.Recognition.Audd)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Integrations.configured?(:audd), do: run(args), else: :ok
  end

  defp run(%{"segment_id" => sid}) do
    case Segment |> Repo.get(sid) |> Repo.preload(:mix) do
      %Segment{mix: %{audio_path: path, audio_deleted_at: nil} = mix} = seg when is_binary(path) ->
        # Never re-identify (or risk overwriting) an already-named segment.
        if named?(seg), do: :ok, else: recognize(seg, path, mix.id)

      _ ->
        :ok
    end
  end

  defp run(%{"mix_id" => mix_id}) do
    case Mixes.get_with_segments(mix_id) do
      %{audio_path: path, audio_deleted_at: nil} = mix when is_binary(path) ->
        targets = Enum.reject(mix.segments, &named?/1)
        total = length(targets)

        targets
        |> Enum.with_index(1)
        |> Enum.each(fn {seg, i} ->
          recognize(seg, path, mix.id)
          Mixes.broadcast(%{mix_id: mix.id, stage: "recognize", done: i, total: total})
        end)

      _ ->
        :ok
    end
  end

  defp recognize(seg, path, mix_id) do
    case @recognizer.identify(path, seg.start_ms, seg.end_ms || seg.start_ms) do
      {:ok, %{artist: a, title: t}} ->
        match = Mixes.match_track(a, t)

        Mixes.update_segment(seg, %{
          artist: a,
          title: t,
          name_source: :fingerprint,
          matched_track_id: match && match.track_id,
          match_confidence: match && match.confidence
        })

      _ ->
        :ok
    end

    Mixes.broadcast(%{mix_id: mix_id, status: :recognized})
    :ok
  end

  defp named?(%{artist: a, title: t}), do: present?(a) or present?(t)
  defp present?(s), do: is_binary(s) and String.trim(s) != ""
end
