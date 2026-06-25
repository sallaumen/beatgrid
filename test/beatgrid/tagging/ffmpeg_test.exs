defmodule Beatgrid.Tagging.FfmpegTest do
  # `:ffmpeg`-tagged: shells out to the real ffmpeg/ffprobe binaries; excluded by
  # default (run with `mix test --include ffmpeg`).
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.{Ffprobe, Metadata}
  alias Beatgrid.Tagging.Ffmpeg

  @fixture Path.expand(Path.join([__DIR__, "..", "..", "support", "fixtures", "sample.mp3"]))

  @tag :ffmpeg
  @tag :tmp_dir
  test "rewrites the ID3 genre in place via a stream copy, leaving the audio intact", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "song.mp3")
    File.cp!(@fixture, path)

    assert {:ok, %Metadata{genre: "Forró", duration_ms: original_ms}} =
             Ffprobe.read_metadata(path)

    assert :ok = Ffmpeg.write_genre(path, "Forró MPB")
    refute File.exists?(Path.join(dir, ".tagging-song.mp3"))

    assert {:ok, %Metadata{genre: "Forró MPB", duration_ms: new_ms}} = Ffprobe.read_metadata(path)
    # audio untouched — duration is unchanged by a metadata-only stream copy
    assert_in_delta new_ms, original_ms, 60
  end
end
