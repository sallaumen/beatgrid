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

    test "bpm range uses the effective value (detected when no Soundcharts)" do
      s = insert(:soundcharts_song, tempo_bpm: 128.0)
      sc = insert(:track, status: :present, soundcharts_song_id: s.id)
      detected = insert(:track, status: :present, bpm_detected: 124.0)
      insert(:track, status: :present, bpm_detected: 90.0)

      ids = TrackQuery.library(%{bpm_min: 120, bpm_max: 130}) |> Enum.map(& &1.id)
      assert sc.id in ids
      assert detected.id in ids
      assert length(ids) == 2
    end

    test "sorts by a chosen field + direction (nils last)" do
      s1 = insert(:soundcharts_song, tempo_bpm: 150.0)
      s2 = insert(:soundcharts_song, tempo_bpm: 100.0)
      fast = insert(:track, status: :present, soundcharts_song_id: s1.id, norm_artist: "z")
      slow = insert(:track, status: :present, soundcharts_song_id: s2.id, norm_artist: "a")
      nobpm = insert(:track, status: :present, norm_artist: "m")

      ids = TrackQuery.library(%{sort: {:bpm, :desc}}) |> Enum.map(& &1.id)
      # nil bpm last
      assert ids == [fast.id, slow.id, nobpm.id]
    end

    test "filters by compatible key, energy range, rating_max, unclassified" do
      s8a = insert(:soundcharts_song, camelot: "8A", energy: 0.7)
      s3b = insert(:soundcharts_song, camelot: "3B", energy: 0.2)

      keep =
        insert(:track,
          status: :present,
          genre_folder: "mpb",
          rating: 6,
          soundcharts_song_id: s8a.id
        )

      far =
        insert(:track,
          status: :present,
          genre_folder: "mpb",
          rating: 6,
          soundcharts_song_id: s3b.id
        )

      inbox = insert(:track, status: :present, genre_folder: nil)

      ids = TrackQuery.library(%{camelot: "8A", camelot_compatible: true}) |> Enum.map(& &1.id)
      assert keep.id in ids and far.id not in ids

      energy_ids = TrackQuery.library(%{energy_min: 50, energy_max: 100}) |> Enum.map(& &1.id)
      assert keep.id in energy_ids and far.id not in energy_ids

      rmax_ids = TrackQuery.library(%{rating_max: 5}) |> Enum.map(& &1.id)
      assert keep.id not in rmax_ids and far.id not in rmax_ids

      assert Enum.map(TrackQuery.library(%{unclassified: true}), & &1.id) == [inbox.id]
    end

    test "a decimal BPM filter value parses instead of crashing" do
      song = insert(:soundcharts_song, tempo_bpm: 128.0)
      keep = insert(:track, status: :present, soundcharts_song_id: song.id)
      slow_song = insert(:soundcharts_song, tempo_bpm: 90.0)
      insert(:track, status: :present, soundcharts_song_id: slow_song.id)

      ids = TrackQuery.library(%{bpm_min: "100.5"}) |> Enum.map(& &1.id)
      assert ids == [keep.id]
    end

    test "an unparseable numeric filter is ignored rather than crashing" do
      a = insert(:track, status: :present)
      b = insert(:track, status: :present)

      # "." / "" must not raise; the filter is simply skipped.
      ids = TrackQuery.library(%{bpm_min: ".", rating_max: "abc"}) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    end
  end

  describe "all_tags/0" do
    test "only includes tags from present tracks" do
      insert(:track, status: :present, tags: ["live"])
      insert(:track, status: :quarantined, tags: ["quarantined-only"])
      insert(:track, status: :missing, tags: ["gone"])

      assert TrackQuery.all_tags() == ["live"]
    end
  end
end
