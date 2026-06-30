defmodule Beatgrid.Workers.MixDjVisionWorker do
  @moduledoc "DJ boundaries from on-screen names: one sequential frame-extraction pass, montage locally, OCR via vision, group."
  use Oban.Worker,
    queue: :mixes,
    max_attempts: 10,
    unique: [
      period: 86_400,
      keys: [:mix_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Beatgrid.Mixes
  alias Beatgrid.Mixes.DjVisionAI

  @sampler Application.compile_env(
             :beatgrid,
             [Beatgrid.Video.FrameSampler, :adapter],
             Beatgrid.Video.FrameSampler.FfmpegCli
           )

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mix_id" => mix_id}} = job) do
    case Mixes.get_mix(mix_id) do
      nil -> :ok
      %{duration_ms: nil} -> :ok
      mix -> run(mix, job)
    end
  end

  # Keep the per-task timeout under the Lifeline rescue window (90 min, see config.exs)
  # so Oban terminates + retries a hung yt-dlp/ffmpeg instead of letting Lifeline burn
  # an attempt and block a scarce :mixes queue slot for an hour and a half.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(70)

  @doc "Deterministic per-mix work dir so a retry/Lifeline-rescue reuses an already-downloaded video."
  @spec work_dir(map()) :: String.t()
  def work_dir(mix), do: Path.join(System.tmp_dir!(), "beatgrid-dj-vision-#{mix.id}")

  defp run(mix, job) do
    interval = config(:frame_interval_ms, 30_000)
    per_grid = config(:tiles_per_grid, 9)
    threshold = config(:max_failure_ratio, 0.5)
    dir = work_dir(mix)
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)

    result =
      with {:ok, video} <- ensure_video(mix, dir),
           {:ok, frames} <- @sampler.extract_frames(video, %{interval_ms: interval, dir: dir}) do
        mix |> ocr_frames(frames, interval, per_grid) |> finish(mix, threshold)
      else
        {:error, _} = err -> err
      end

    cleanup(dir, result, job)
    result
  end

  # Clean the work dir on success, and on the FINAL attempt's failure (Oban OSS has no
  # discard hook). On a non-final failure leave it: a retry resumes the partial download
  # (yt-dlp --continue) and reuses already-extracted frames.
  defp cleanup(dir, :ok, _job), do: File.rm_rf(dir)

  defp cleanup(dir, {:error, _}, %Oban.Job{attempt: attempt, max_attempts: max})
       when attempt >= max,
       do: File.rm_rf(dir)

  defp cleanup(_dir, _result, _job), do: :ok

  # Reuse a completed download across retries / Lifeline rescues. yt-dlp writes to a
  # `.part` file and renames to the final name only on success, so a non-`.part`
  # `video.<ext>` is a safe completion marker — never feed a partial file to ffmpeg.
  defp ensure_video(mix, dir) do
    case completed_video(dir) do
      nil -> @sampler.download_video(mix.source_url, dir)
      path -> {:ok, path}
    end
  end

  defp completed_video(dir) do
    dir
    |> Path.join("video.*")
    |> Path.wildcard()
    |> Enum.reject(&(String.ends_with?(&1, ".part") or String.ends_with?(&1, ".ytdl")))
    |> List.first()
  end

  defp ocr_frames(mix, frames, interval, per_grid) do
    groups = frames |> Enum.with_index() |> Enum.chunk_every(per_grid)
    total = length(groups)

    groups
    |> Enum.with_index()
    |> Enum.reduce(%{reads: [], ok: 0, fail: 0, coverage_until_ms: 0}, fn {group, gi}, acc ->
      Mixes.broadcast(%{mix_id: mix.id, stage: "dj_vision", done: gi + 1, total: total})
      paths = Enum.map(group, fn {p, _i} -> p end)
      tiles_ms = Enum.map(group, fn {_p, i} -> i * interval end)
      dest = Path.join(Path.dirname(hd(paths)), "montage-#{gi}.jpg")

      with {:ok, m} <- @sampler.montage(paths, dest),
           {:ok, r} <- DjVisionAI.read_grid(m, tiles_ms) do
        File.rm(m)
        covered = List.last(tiles_ms) + interval

        %{
          acc
          | reads: acc.reads ++ r,
            ok: acc.ok + 1,
            coverage_until_ms: max(acc.coverage_until_ms, covered)
        }
      else
        err ->
          Logger.warning(
            "dj_vision mix #{mix.id} grid #{gi + 1}/#{total} failed: #{inspect(err)}"
          )

          %{acc | fail: acc.fail + 1}
      end
    end)
    |> Map.put(:total, total)
  end

  # No frames extracted (corrupt/empty video): retry rather than persist an empty set,
  # which would wipe any previously-detected DJ parts and write a phantom full-set "no DJ".
  defp finish(%{total: 0}, _mix, _threshold), do: {:error, :no_frames}

  # Every grid failed: don't persist a phantom "complete" result — fail so Oban retries.
  defp finish(%{ok: 0, total: total}, _mix, _threshold),
    do: {:error, {:partial_coverage, 0, total}}

  defp finish(%{ok: ok, fail: fail, total: total} = summary, mix, threshold) do
    if fail / total > threshold do
      Logger.warning(
        "dj_vision mix #{mix.id}: only #{ok}/#{total} grids covered (>#{threshold} failed) — retrying instead of recording a truncated set"
      )

      {:error, {:partial_coverage, ok, total}}
    else
      persist(summary, mix)
    end
  end

  defp persist(%{ok: ok, fail: fail, total: total, reads: reads, coverage_until_ms: cov}, mix) do
    parts =
      reads
      |> DjVisionAI.group_consecutive()
      |> Enum.map(&%{start_ms: &1.start_ms, dj_name: &1.dj_name})

    opts = if fail == 0, do: [], else: [coverage_until_ms: cov]

    Logger.info(
      "dj_vision mix #{mix.id}: #{ok}/#{total} grids ok, #{length(parts)} parts, coverage=#{if fail == 0, do: "full", else: cov}"
    )

    case Mixes.replace_dj_parts(mix, :image, parts, opts) do
      {:ok, _} -> :ok
      {:error, :manual_present} -> :ok
    end
  end

  defp config(key, default),
    do: :beatgrid |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
