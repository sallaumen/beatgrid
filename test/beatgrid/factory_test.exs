defmodule Beatgrid.FactoryTest do
  use Beatgrid.DataCase, async: true

  # The suites lean on ExMachina.Ecto's belongs_to handling instead of the
  # hand-rolled insert-song-then-track pair. Pin both forms it must support.
  test "insert(:track, soundcharts_song: ...) persists the song and links the FK" do
    track = insert(:track, soundcharts_song: build(:soundcharts_song, camelot: "8A"))

    assert track.soundcharts_song.id
    assert track.soundcharts_song_id == track.soundcharts_song.id
    assert track.soundcharts_song.camelot == "8A"
  end

  test "an already-inserted song is reused, not duplicated" do
    song = insert(:soundcharts_song)

    a = insert(:track, soundcharts_song: song)
    b = insert(:track, soundcharts_song: song)

    assert a.soundcharts_song_id == song.id
    assert b.soundcharts_song_id == song.id
    assert Repo.aggregate(Beatgrid.Soundcharts.Song, :count) == 1
  end
end
