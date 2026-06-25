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
end
