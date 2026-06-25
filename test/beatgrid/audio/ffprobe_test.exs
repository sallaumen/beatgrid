defmodule Beatgrid.Audio.FfprobeTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.{Ffprobe, Metadata}

  @fixture Path.expand(Path.join([__DIR__, "..", "..", "support", "fixtures", "sample.mp3"]))

  @tag :ffprobe
  test "reads metadata from a real mp3 via ffprobe" do
    assert {:ok, %Metadata{} = m} = Ffprobe.read_metadata(@fixture)

    assert m.title == "Test Title"
    assert m.artist == "Test Artist"
    assert m.album == "Test Album"
    assert m.genre == "Forró"
    assert m.year == 2020
    assert m.track_no == 3
    assert m.sample_rate_hz == 44_100
    assert m.channels == 2
    assert m.format_name =~ "mp3"
    assert m.duration_ms in 900..1200
    assert m.bitrate_kbps in 300..360
  end

  @tag :ffprobe
  @tag :tmp_dir
  test "returns an error for a non-audio file", %{tmp_dir: dir} do
    path = Path.join(dir, "notes.txt")
    File.write!(path, "this is plainly not audio")

    assert {:error, _reason} = Ffprobe.read_metadata(path)
  end

  test "returns an error when the file does not exist" do
    assert {:error, :enoent} = Ffprobe.read_metadata("/no/such/file.mp3")
  end
end
