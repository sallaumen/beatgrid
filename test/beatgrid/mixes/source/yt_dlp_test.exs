defmodule Beatgrid.Mixes.Source.YtDlpTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Mixes.Source.YtDlp

  test "parse_meta/2 builds the meta map and JSON-decodes the multi-line description" do
    # yt-dlp --print emits: id \t title \t uploader \t duration(secs) \t description(JSON)
    line =
      [
        "abc123",
        "Live @ Awakenings",
        "DJ Tester",
        "3600.0",
        ~s("Tracklist:\\n00:00 A - B\\n04:30 C - D")
      ]
      |> Enum.join("\t")

    assert {:ok, meta} = YtDlp.parse_meta(line <> "\n", "/tmp/_Mixes")
    assert meta.audio_path == "/tmp/_Mixes/abc123.mp3"
    assert meta.title == "Live @ Awakenings"
    assert meta.dj == "DJ Tester"
    assert meta.duration_ms == 3_600_000
    assert meta.description =~ "00:00 A - B"
    assert meta.description =~ "04:30 C - D"
  end

  test "parse_meta/2 returns :no_metadata on a malformed line" do
    assert {:error, :no_metadata} = YtDlp.parse_meta("garbage\n", "/tmp/_Mixes")
  end
end
