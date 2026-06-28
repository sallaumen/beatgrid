defmodule Beatgrid.Mixes.Source.YtDlpTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Mixes.Source.YtDlp

  test "parse_meta/2 builds the meta map and JSON-decodes the multi-line description" do
    # yt-dlp --print emits: id \t title \t uploader \t duration(secs) \t description(JSON) \t chapters(JSON)
    line =
      [
        "abc123",
        "Live @ Awakenings",
        "DJ Tester",
        "3600.0",
        ~s("Tracklist:\\n00:00 A - B\\n04:30 C - D"),
        "NA"
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

  test "parse_meta extracts chapters" do
    chapters_json =
      Jason.encode!([
        %{"start_time" => 0, "title" => "DJ A"},
        %{"start_time" => 3600.0, "title" => "DJ B"}
      ])

    line =
      ["vid123", "Festival", "Uploader", "10800", Jason.encode!("desc"), chapters_json]
      |> Enum.join("\t")

    assert {:ok, meta} = YtDlp.parse_meta(line, "/tmp/dest")
    assert meta.chapters == [%{start_ms: 0, title: "DJ A"}, %{start_ms: 3_600_000, title: "DJ B"}]
  end

  test "parse_meta tolerates absent/empty chapters" do
    line = ["v", "T", "U", "60", Jason.encode!("d"), "NA"] |> Enum.join("\t")
    assert {:ok, meta} = YtDlp.parse_meta(line, "/tmp/dest")
    assert meta.chapters == []
  end
end
