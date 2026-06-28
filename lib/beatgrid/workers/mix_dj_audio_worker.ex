defmodule Beatgrid.Workers.MixDjAudioWorker do
  @moduledoc "Best-effort DJ boundaries from audio novelty peaks (button-triggered)."
  use Oban.Worker,
    queue: :mixes,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:mix_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Beatgrid.Mixes

  @segmenter Application.compile_env(
               :beatgrid,
               [Beatgrid.Audio.SetSegmenter, :adapter],
               Beatgrid.Audio.SetSegmenter.LibrosaCli
             )

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mix_id" => mix_id}}) do
    case Mixes.get_mix(mix_id) do
      nil -> :ok
      %{audio_path: nil} -> :ok
      mix -> run_detection(mix)
    end
  end

  defp run_detection(mix) do
    with {:ok, candidates} <- @segmenter.dj_candidates(mix.audio_path) do
      parts = Enum.map(candidates, &%{start_ms: &1.start_ms, dj_name: nil})
      apply_parts(mix, parts)
    end
  end

  defp apply_parts(mix, parts) do
    case Mixes.replace_dj_parts(mix, :audio, parts) do
      {:ok, _n} ->
        Mixes.broadcast(%{mix_id: mix.id, stage: "dj_audio", done: 1, total: 1})
        :ok

      {:error, :manual_present} ->
        :ok
    end
  end
end
