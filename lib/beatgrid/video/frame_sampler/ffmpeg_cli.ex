defmodule Beatgrid.Video.FrameSampler.FfmpegCli do
  @moduledoc """
  FrameSampler adapter: three-step pipeline.

  1. `download_video/2` — yt-dlp downloads a low-res (<=360p) copy of the video into a
     local directory. Downloading beats googlevideo stream throttling (which limits to
     ~realtime, making frame extraction from a 4h video take ~3 hours).
  2. `extract_frames/2` — ONE sequential ffmpeg pass from the LOCAL file (no random -ss
     seeks): extracts a cropped lower-third frame every N seconds into a local directory.
     Reading from disk is instant compared to streaming over HTTP.
  3. `montage/2` — assembles already-extracted local frames into one xstack image for OCR.

  No `drawtext` (not all ffmpeg builds ship libfreetype) — tiles are ordered
  left-to-right/top-to-bottom and the caller aligns them to timestamps by position.
  """
  @behaviour Beatgrid.Video.FrameSampler

  @impl true
  def download_video(url, dir) do
    out = Path.join(dir, "video.%(ext)s")
    args = ["-f", "bv*[height<=360]/b[height<=360]/worst", "--no-playlist", "-o", out, url]

    case System.cmd(ytdlp(), args, stderr_to_stdout: true) do
      {_o, 0} ->
        case dir |> Path.join("video.*") |> Path.wildcard() |> List.first() do
          nil -> {:error, :no_video_file}
          path -> {:ok, path}
        end

      {o, code} ->
        {:error, {:ytdlp_exit, code, tail_excerpt(o)}}
    end
  end

  @impl true
  def extract_frames(video_path, %{interval_ms: interval_ms, dir: dir}) do
    secs = max(1, div(interval_ms, 1000))
    pattern = Path.join(dir, "f%05d.jpg")
    args = ["-nostdin", "-i", video_path, "-vf", "fps=1/#{secs},crop=iw:ih/3:0:ih*2/3,scale=320:-2", "-q:v", "4", pattern]

    case System.cmd(ffmpeg(), args, stderr_to_stdout: true) do
      {_out, 0} -> {:ok, dir |> Path.join("f*.jpg") |> Path.wildcard() |> Enum.sort()}
      {out, code} -> {:error, {:ffmpeg_exit, code, tail_excerpt(out)}}
    end
  end

  @impl true
  def montage(frame_paths, dest) do
    case System.cmd(ffmpeg(), build_montage_args(frame_paths, dest), stderr_to_stdout: true) do
      {_out, 0} -> {:ok, dest}
      {out, code} -> {:error, {:ffmpeg_exit, code, tail_excerpt(out)}}
    end
  end

  @doc "ffmpeg argv to xstack already-cropped local frames into one reading-order montage."
  @spec build_montage_args([String.t()], String.t()) :: [String.t()]
  def build_montage_args(frame_paths, dest) do
    inputs = Enum.flat_map(frame_paths, fn p -> ["-i", p] end)
    n = length(frame_paths)

    filter =
      if n == 1 do
        "[0:v]copy[out]"
      else
        cols = max(1, round(:math.sqrt(n)))
        tags = Enum.map_join(0..(n - 1), "", &"[#{&1}:v]")
        "#{tags}xstack=inputs=#{n}:layout=#{xstack_layout(n, cols)}[out]"
      end

    inputs ++ ["-filter_complex", filter, "-map", "[out]", "-frames:v", "1", "-y", dest]
  end

  defp xstack_layout(n, cols) do
    Enum.map_join(0..(n - 1), "|", fn i -> xstack_cell(i, cols) end)
  end

  defp xstack_cell(i, cols) do
    col = rem(i, cols)
    row = div(i, cols)
    "#{xstack_coord(col, "w0")}_#{xstack_coord(row, "h0")}"
  end

  defp xstack_coord(0, _unit), do: "0"
  defp xstack_coord(n, unit), do: Enum.map_join(1..n, "+", fn _ -> unit end)

  defp tail_excerpt(out), do: out |> String.split("\n", trim: true) |> Enum.take(-4) |> Enum.join(" | ") |> String.slice(0, 500)

  defp ytdlp, do: Application.get_env(:beatgrid, __MODULE__, [])[:ytdlp] || "yt-dlp"
  defp ffmpeg, do: Application.get_env(:beatgrid, __MODULE__, [])[:ffmpeg] || "ffmpeg"
end
