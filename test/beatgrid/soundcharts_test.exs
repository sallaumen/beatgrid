defmodule Beatgrid.SoundchartsTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Soundcharts
  alias Beatgrid.Soundcharts.{Mock, Response}

  defp search_response(items, quota \\ 999) do
    {:ok, %Response{data: items, quota_remaining: quota, status: 200}}
  end

  defp song_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        sc_uuid: "uuid-1",
        name: "Disritmia",
        credit_name: "Casuarina",
        isrc: "BRKMM0900046",
        release_date: ~D[2010-01-05],
        label: "Agente Digital",
        genres: [],
        tempo_bpm: 141.57,
        music_key: 11,
        music_mode: 0,
        energy: 0.63,
        valence: 0.87,
        danceability: 0.72,
        raw: %{}
      },
      overrides
    )
  end

  describe "resolve_track/1" do
    test "matches by artist, fetches metadata, caches the song, links the track, logs calls" do
      track =
        insert(:track,
          tag_title: "Disritmia",
          tag_artist: "Casuarina",
          norm_artist: "casuarina",
          norm_title: "disritmia"
        )

      expect(Mock, :search_song, fn "Disritmia" ->
        search_response([
          %{uuid: "other", name: "Disritmia", credit_name: "Martinho da Vila", release_date: nil},
          %{uuid: "uuid-1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}
        ])
      end)

      expect(Mock, :get_song, fn "uuid-1" ->
        {:ok, %Response{data: song_attrs(), quota_remaining: 998, status: 200}}
      end)

      assert {:ok, song} = Soundcharts.resolve_track(track)
      assert song.sc_uuid == "uuid-1"
      assert song.tempo_bpm == 141.57
      # key 11, mode 0 (B minor) → 10A
      assert song.camelot == "10A"

      assert Tracks.get(track.id).soundcharts_song_id == song.id
      assert Soundcharts.budget().used == 2
    end

    test "is a no-op when the track is already linked (makes no API calls)" do
      song = insert(:soundcharts_song)
      track = insert(:track, soundcharts_song_id: song.id)

      # No Mox expectations set: any call would fail verify_on_exit!.
      assert {:ok, :already_linked} = Soundcharts.resolve_track(track)
    end

    test "returns :no_match when the search yields nothing" do
      track = insert(:track, tag_title: "Nope", tag_artist: "Nobody", norm_artist: "nobody")

      expect(Mock, :search_song, fn _term -> search_response([]) end)

      assert {:error, :no_match} = Soundcharts.resolve_track(track)
    end

    test "caches: two tracks of the same song share one Song row" do
      t1 =
        insert(:track, tag_title: "Disritmia", tag_artist: "Casuarina", norm_artist: "casuarina")

      t2 =
        insert(:track, tag_title: "Disritmia", tag_artist: "Casuarina", norm_artist: "casuarina")

      item = %{uuid: "uuid-1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}
      expect(Mock, :search_song, 2, fn _ -> search_response([item]) end)

      expect(Mock, :get_song, 2, fn "uuid-1" ->
        {:ok, %Response{data: song_attrs(), quota_remaining: 997, status: 200}}
      end)

      assert {:ok, song1} = Soundcharts.resolve_track(t1)
      assert {:ok, song2} = Soundcharts.resolve_track(t2)
      assert song1.id == song2.id
      assert Soundcharts.song_count() == 1
    end
  end

  describe "match confidence (tracks.sc_match_confidence)" do
    defp resolve_with_item(track, item) do
      expect(Mock, :search_song, fn _term -> search_response([item]) end)

      expect(Mock, :get_song, fn uuid ->
        {:ok, %Response{data: song_attrs(%{sc_uuid: uuid}), quota_remaining: 998, status: 200}}
      end)

      assert {:ok, _song} = Soundcharts.resolve_track(track)
      Tracks.get(track.id).sc_match_confidence
    end

    test "high when artist and title both match" do
      track =
        insert(:track,
          tag_title: "Disritmia",
          tag_artist: "Casuarina",
          norm_artist: "casuarina",
          norm_title: "disritmia"
        )

      item = %{uuid: "u1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}
      assert resolve_with_item(track, item) == :high
    end

    test "medium when artist matches but the title differs (medley)" do
      track =
        insert(:track,
          tag_title: "Ela Tem",
          tag_artist: "Mestrinho",
          norm_artist: "mestrinho",
          norm_title: "ela tem"
        )

      item = %{
        uuid: "u1",
        name: "Mete um Block / Ela Tem",
        credit_name: "Mestrinho",
        release_date: nil
      }

      assert resolve_with_item(track, item) == :medium
    end

    test "low when neither artist nor title is confirmed (top-hit fallback)" do
      track =
        insert(:track,
          tag_title: "Baiao",
          tag_artist: "Somebody",
          norm_artist: "somebody",
          norm_title: "baiao"
        )

      item = %{uuid: "u1", name: "A Medley", credit_name: "Wesley Safadão", release_date: nil}
      assert resolve_with_item(track, item) == :low
    end
  end

  describe "truncated-download detector" do
    test "flags :truncated when the physical file is much shorter than the cloud duration" do
      track =
        insert(:track,
          tag_title: "X",
          tag_artist: "Y",
          norm_artist: "y",
          duration_ms: 60_000,
          quality_issues: []
        )

      expect(Mock, :search_song, fn _ ->
        search_response([%{uuid: "u1", name: "X", credit_name: "Y", release_date: nil}])
      end)

      expect(Mock, :get_song, fn "u1" ->
        {:ok,
         %Response{
           data: song_attrs(%{sc_uuid: "u1", duration_seconds: 200}),
           quota_remaining: 998,
           status: 200
         }}
      end)

      assert {:ok, _song} = Soundcharts.resolve_track(track)
      assert :truncated in Tracks.get(track.id).quality_issues
    end

    test "does not flag :truncated when the durations agree" do
      track =
        insert(:track,
          tag_title: "X",
          tag_artist: "Y",
          norm_artist: "y",
          duration_ms: 198_000,
          quality_issues: []
        )

      expect(Mock, :search_song, fn _ ->
        search_response([%{uuid: "u2", name: "X", credit_name: "Y", release_date: nil}])
      end)

      expect(Mock, :get_song, fn "u2" ->
        {:ok,
         %Response{
           data: song_attrs(%{sc_uuid: "u2", duration_seconds: 200}),
           quota_remaining: 998,
           status: 200
         }}
      end)

      assert {:ok, _song} = Soundcharts.resolve_track(track)
      refute :truncated in Tracks.get(track.id).quality_issues
    end
  end

  describe "backfill/0" do
    test "re-derives Lean+ columns, confidence and truncated from cached raw (no API)" do
      raw = %{
        "uuid" => "u9",
        "name" => "Forrózão",
        "creditName" => "Fulano",
        "duration" => 200,
        "languageCode" => "pt-BR",
        "imageUrl" => "http://i",
        "genres" => [%{"root" => "latin", "sub" => ["forró"]}],
        "mainArtists" => [%{"uuid" => "a1", "name" => "Fulano"}],
        "audio" => %{"tempo" => 120.0, "key" => 0, "mode" => 1, "timeSignature" => 4}
      }

      song =
        insert(:soundcharts_song,
          sc_uuid: "u9",
          name: "Forrózão",
          credit_name: "Fulano",
          raw: raw
        )

      track =
        insert(:track,
          tag_artist: "Fulano",
          tag_title: "Forrózão",
          norm_artist: "fulano",
          norm_title: "forrozao",
          duration_ms: 60_000,
          quality_issues: [],
          soundcharts_song_id: song.id
        )

      assert %{songs: 1, tracks: 1} = Soundcharts.backfill()

      song = Repo.get!(Beatgrid.Soundcharts.Song, song.id)
      assert song.duration_seconds == 200
      assert song.subgenres == ["forró"]
      assert song.time_signature == 4
      assert song.sc_artist_uuid == "a1"

      track = Tracks.get(track.id)
      assert track.sc_match_confidence == :high
      assert :truncated in track.quality_issues
    end
  end
end
