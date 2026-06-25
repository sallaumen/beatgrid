defmodule Beatgrid.Library.ScannerTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library.{Scanner, Tracks}

  defp healthy(title, artist) do
    {:ok, %Metadata{title: title, artist: artist, bitrate_kbps: 320, duration_ms: 200_000}}
  end

  @tag :tmp_dir
  test "scans audio files and persists tracks with metadata + quality flags", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "MPB"))
    File.write!(Path.join(root, "MPB/good.mp3"), "fake-good")
    File.write!(Path.join(root, "MPB/bad.mp3"), "fake-bad")
    File.write!(Path.join(root, "MPB/notes.txt"), "ignore me")

    insert(:genre_folder, dir_name: "MPB", key: "mpb")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn path ->
      if String.ends_with?(path, "good.mp3"),
        do: healthy("Good Song", "Some Artist"),
        else: {:error, :not_audio}
    end)

    assert {:ok, %{scanned: 2}} = Scanner.scan(root)

    good = Tracks.get_by_path("MPB/good.mp3")
    assert good.tag_title == "Good Song"
    assert good.norm_title == "good song"
    assert good.format == :mp3
    assert good.genre_folder == "mpb"
    assert good.source_playlist == "MPB"
    assert good.content_sha256 != nil
    assert good.quality_issues == []
    assert good.status == :present

    bad = Tracks.get_by_path("MPB/bad.mp3")
    assert bad.quality_issues == [:not_audio]

    # non-audio extensions are skipped entirely
    assert Tracks.get_by_path("MPB/notes.txt") == nil
  end

  @tag :tmp_dir
  test "marks tracks whose files disappeared as missing (when asked)", %{tmp_dir: root} do
    path = Path.join(root, "x.mp3")
    File.write!(path, "data")
    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ -> healthy("X", "Y") end)

    {:ok, _} = Scanner.scan(root, mark_missing: true)
    assert Tracks.get_by_path("x.mp3").status == :present

    File.rm!(path)
    {:ok, _} = Scanner.scan(root, mark_missing: true)
    assert Tracks.get_by_path("x.mp3").status == :missing
  end
end
