defmodule Beatgrid.RepertoireTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Repertoire

  describe "overview/0" do
    test "counts present tracks, resolved/unresolved, truncated and confidence" do
      song = insert(:soundcharts_song)
      insert(:track, status: :present, soundcharts_song_id: song.id, sc_match_confidence: :high)

      insert(:track,
        status: :present,
        soundcharts_song_id: song.id,
        sc_match_confidence: :low,
        quality_issues: [:truncated]
      )

      insert(:track, status: :present)
      insert(:track, status: :quarantined)

      overview = Repertoire.overview()
      assert overview.total == 3
      assert overview.resolved == 2
      assert overview.unresolved == 1
      assert overview.truncated == 1
      assert overview.by_confidence == %{high: 1, low: 1}
    end
  end

  describe "distributions" do
    test "genre_distribution/0 counts present tracks per folder" do
      insert(:track, status: :present, genre_folder: "mpb")
      insert(:track, status: :present, genre_folder: "mpb")
      insert(:track, status: :present, genre_folder: "forro_roots")

      assert Repertoire.genre_distribution() == %{"mpb" => 2, "forro_roots" => 1}
    end

    test "top_artists/1 ranks by track count" do
      insert(:track, status: :present, tag_artist: "Djavan")
      insert(:track, status: :present, tag_artist: "Djavan")
      insert(:track, status: :present, tag_artist: "Gal Costa")

      assert Repertoire.top_artists(1) == [{"Djavan", 2}]
    end

    test "bpm_histogram/1 buckets resolved tracks" do
      for bpm <- [122.0, 128.0, 141.0] do
        song = insert(:soundcharts_song, tempo_bpm: bpm)
        insert(:track, soundcharts_song_id: song.id)
      end

      assert Repertoire.bpm_histogram(10) == %{120 => 2, 140 => 1}
    end

    test "decade_distribution/0 buckets by release decade" do
      s_1 = insert(:soundcharts_song, release_date: ~D[1987-03-01])
      s_2 = insert(:soundcharts_song, release_date: ~D[2010-06-01])
      insert(:track, soundcharts_song_id: s_1.id)
      insert(:track, soundcharts_song_id: s_2.id)

      assert Repertoire.decade_distribution() == %{1980 => 1, 2010 => 1}
    end
  end

  describe "recommendations" do
    test "create, list and count recommendations by scope/status" do
      {:ok, _} =
        Repertoire.create_recommendation(%{
          artist: "A",
          song: "S",
          source: :gaps,
          genre_folder: "mpb",
          youtube_query: "A S"
        })

      assert [%{artist: "A"}] =
               Repertoire.list_recommendations(genre_folder: "mpb", source: :gaps)

      assert Repertoire.count_recommendations(
               genre_folder: "mpb",
               source: :gaps,
               statuses: [:new, :imported]
             ) == 1
    end

    test "youtube_search_url encodes the query" do
      rec = %Beatgrid.Repertoire.Recommendation{youtube_query: "Elis Águas de Março"}
      assert Repertoire.youtube_search_url(rec) =~ "search_query=Elis+%C3%81guas"
    end
  end
end
