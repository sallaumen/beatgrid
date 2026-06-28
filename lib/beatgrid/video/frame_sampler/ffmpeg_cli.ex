defmodule Beatgrid.Video.FrameSampler.FfmpegCli do
  @moduledoc "FrameSampler adapter: yt-dlp -g to resolve the stream, ffmpeg to build a labeled lower-third montage."
  @behaviour Beatgrid.Video.FrameSampler

  @impl true
  def resolve_stream(url) do
    case System.cmd(ytdlp(), ["-g", "-f", "bv*[height<=720]/b", "--no-playlist", url], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> List.first()}
      {out, code} -> {:error, {:ytdlp_exit, code, String.slice(out, 0, 300)}}
    end
  end

  @impl true
  def sample_grid(stream_url, %{tiles: tiles, dest: dest}) do
    case System.cmd(ffmpeg(), build_grid_args(stream_url, tiles, dest), stderr_to_stdout: true) do
      {_out, 0} -> {:ok, dest}
      {out, code} -> {:error, {:ffmpeg_exit, code, String.slice(out, 0, 300)}}
    end
  end

  @doc "ffmpeg argv: one -ss input per tile, crop bottom third, label with ts, tile into a grid."
  @spec build_grid_args(String.t(), [integer()], String.t()) :: [String.t()]
  def build_grid_args(stream_url, tiles, dest) do
    inputs = Enum.flat_map(tiles, fn ms -> ["-ss", "#{ms / 1000}", "-i", stream_url] end)
    n = length(tiles)

    labels =
      Enum.map_join(Enum.with_index(tiles), ";", fn {ms, i} ->
        "[#{i}:v]crop=iw:ih/3:0:ih*2/3,scale=320:-1," <>
          "drawtext=text='#{div(ms, 1000)}s':x=4:y=4:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.5[t#{i}]"
      end)

    filter =
      if n == 1 do
        "#{labels}"
        |> String.replace_suffix("[t0]", "[out]")
      else
        cols = max(1, round(:math.sqrt(n)))
        tags = Enum.map_join(0..(n - 1), "", &"[t#{&1}]")
        "#{labels};#{tags}xstack=inputs=#{n}:layout=#{xstack_layout(n, cols)}[out]"
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

  defp ytdlp, do: Application.get_env(:beatgrid, __MODULE__, [])[:ytdlp] || "yt-dlp"
  defp ffmpeg, do: Application.get_env(:beatgrid, __MODULE__, [])[:ffmpeg] || "ffmpeg"
end
