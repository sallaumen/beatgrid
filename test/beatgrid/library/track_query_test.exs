defmodule Beatgrid.Library.TrackQueryTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library.TrackQuery

  describe "library/1" do
    test "filters present tracks by genre, rating, tag, BPM range and search; preloads song" do
      song = insert(:soundcharts_song, tempo_bpm: 120.0, camelot: "8A")

      keep =
        insert(:track,
          status: :present,
          genre_folder: "mpb",
          rating: 8,
          tags: ["festa", "abertura"],
          tag_artist: "Djavan",
          norm_artist: "djavan",
          soundcharts_song_id: song.id
        )

      insert(:track, status: :present, genre_folder: "forro_roots", rating: 8)
      insert(:track, status: :present, genre_folder: "mpb", rating: 3)
      insert(:track, status: :quarantined, genre_folder: "mpb", rating: 9)

      result =
        TrackQuery.library(%{
          genre_folder: "mpb",
          rating_min: 5,
          tag: "festa",
          bpm_min: 100,
          bpm_max: 130,
          search: "djav"
        })

      assert Enum.map(result, & &1.id) == [keep.id]
      assert hd(result).soundcharts_song.camelot == "8A"
    end

    test "no filters returns all present tracks" do
      insert(:track, status: :present)
      insert(:track, status: :present)
      insert(:track, status: :missing)

      assert length(TrackQuery.library(%{})) == 2
    end
  end
end
