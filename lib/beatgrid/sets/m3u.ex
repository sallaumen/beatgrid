defmodule Beatgrid.Sets.M3u do
  @moduledoc """
  Pure `.m3u` rendering for a set's tracks — body text and a filesystem-safe
  filename. `Beatgrid.Sets.export_m3u/1` owns the disk write.
  """

  @unsafe ~r/[\/\\:*?"<>|]/u

  @doc "The playlist body: `#EXTM3U` plus an `#EXTINF` + absolute-path pair per track."
  @spec body([map()], Path.t()) :: String.t()
  def body(tracks, root) do
    lines = Enum.flat_map(tracks, &extinf(&1, root))
    Enum.join(["#EXTM3U" | lines], "\n") <> "\n"
  end

  @doc "Sanitized `<name>.m3u` (path-hostile characters swapped for dashes)."
  @spec filename(String.t() | nil) :: String.t()
  def filename(name) do
    sanitized = (name || "set") |> String.replace(@unsafe, "-") |> String.trim()
    sanitized <> ".m3u"
  end

  defp extinf(track, root) do
    secs = if track.duration_ms, do: div(track.duration_ms, 1000), else: -1
    artist = track.tag_artist || "—"
    title = track.tag_title || track.filename
    ["#EXTINF:#{secs},#{artist} - #{title}", Path.join(root, track.rel_path)]
  end
end
