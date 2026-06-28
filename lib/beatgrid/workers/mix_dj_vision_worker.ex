defmodule Beatgrid.Workers.MixDjVisionWorker do
  @moduledoc "DJ boundaries from on-screen names: sample a dense montage, OCR via vision, group."
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
      dir = Path.join(System.tmp_dir!(), "beatgrid-dj-vision-#{mix.id}")
      File.mkdir_p!(dir)
      File.chmod(dir, 0o700)

      try do
        windows = windows(mix.duration_ms)
        total = length(windows)

        reads =
          windows
          |> Enum.with_index()
          |> Enum.flat_map(fn window -> sample_window(mix, stream, window, total, dir) end)

        parts =
          reads
          |> DjVisionAI.group_consecutive()
          |> Enum.map(&%{start_ms: &1.start_ms, dj_name: &1.dj_name})

        case Mixes.replace_dj_parts(mix, :image, parts) do
          {:ok, _} -> :ok
          {:error, :manual_present} -> :ok
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp sample_window(mix, stream, {tiles, i}, total, dir) do
    Mixes.broadcast(%{mix_id: mix.id, stage: "dj_vision", done: i + 1, total: total})
    dest = Path.join(dir, "grid-#{i}.jpg")

    case @sampler.sample_grid(stream, %{tiles: tiles, dest: dest}) do
      {:ok, path} ->
        result = DjVisionAI.read_grid(path, tiles)

        case result do
          {:ok, reads} -> reads
          _ -> []
        end

      _ ->
        []
    end
  end

  defp windows(duration_ms) do
    interval = config(:frame_interval_ms, 10_000)
    per_grid = config(:tiles_per_grid, 16)

    0
    |> Stream.iterate(&(&1 + interval))
    |> Stream.take_while(&(&1 < duration_ms))
    |> Enum.chunk_every(per_grid)
  end

  defp config(key, default),
    do: :beatgrid |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
