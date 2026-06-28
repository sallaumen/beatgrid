defmodule Beatgrid.Workers.MixDjVisionWorker do
  @moduledoc "DJ boundaries from on-screen names: one sequential frame-extraction pass, montage locally, OCR via vision, group."
  use Oban.Worker,
    queue: :mixes,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:mix_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Beatgrid.Mixes
  alias Beatgrid.Mixes.DjVisionAI

  @sampler Application.compile_env(
             :beatgrid,
             [Beatgrid.Video.FrameSampler, :adapter],
             Beatgrid.Video.FrameSampler.FfmpegCli
           )

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mix_id" => mix_id}}) do
    case Mixes.get_mix(mix_id) do
      nil -> :ok
      %{duration_ms: nil} -> :ok
      mix -> run(mix)
    end
  end

  defp run(mix) do
    with {:ok, stream} <- @sampler.resolve_stream(mix.source_url) do
      interval = config(:frame_interval_ms, 30_000)
      per_grid = config(:tiles_per_grid, 16)
      dir = Path.join(System.tmp_dir!(), "beatgrid-dj-vision-#{mix.id}")
      File.mkdir_p!(dir)
      File.chmod(dir, 0o700)

      try do
        case @sampler.extract_frames(stream, %{interval_ms: interval, dir: dir}) do
          {:ok, frames} ->
            reads = ocr_frames(mix, frames, interval, per_grid)
            parts = reads |> DjVisionAI.group_consecutive() |> Enum.map(&%{start_ms: &1.start_ms, dj_name: &1.dj_name})

            case Mixes.replace_dj_parts(mix, :image, parts) do
              {:ok, _} -> :ok
              {:error, :manual_present} -> :ok
            end

          {:error, _} = err ->
            err
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp ocr_frames(mix, frames, interval, per_grid) do
    groups = frames |> Enum.with_index() |> Enum.chunk_every(per_grid)
    total = length(groups)

    groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, gi} ->
      Mixes.broadcast(%{mix_id: mix.id, stage: "dj_vision", done: gi + 1, total: total})
      paths = Enum.map(group, fn {p, _i} -> p end)
      tiles_ms = Enum.map(group, fn {_p, i} -> i * interval end)
      dest = Path.join(Path.dirname(hd(paths)), "montage-#{gi}.jpg")

      with {:ok, m} <- @sampler.montage(paths, dest),
           {:ok, r} <- DjVisionAI.read_grid(m, tiles_ms) do
        File.rm(m)
        r
      else
        _ -> []
      end
    end)
  end

  defp config(key, default),
    do: :beatgrid |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
