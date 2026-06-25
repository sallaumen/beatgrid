defmodule Beatgrid.Workers.ResolveSongWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Soundcharts.{Mock, Response}
  alias Beatgrid.Workers.ResolveSongWorker

  test "resolves the track referenced by the job" do
    track =
      insert(:track, tag_title: "Disritmia", tag_artist: "Casuarina", norm_artist: "casuarina")

    expect(Mock, :search_song, fn _term ->
      {:ok,
       %Response{
         data: [%{uuid: "u1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}],
         quota_remaining: 999,
         status: 200
       }}
    end)

    expect(Mock, :get_song, fn "u1" ->
      {:ok,
       %Response{
         data: %{sc_uuid: "u1", name: "Disritmia", music_key: 11, music_mode: 0, raw: %{}},
         quota_remaining: 998,
         status: 200
       }}
    end)

    assert :ok = perform_job(ResolveSongWorker, %{"track_id" => track.id})
    assert Tracks.get(track.id).soundcharts_song_id
  end

  test "cancels when the track no longer exists" do
    assert {:cancel, :track_not_found} =
             perform_job(ResolveSongWorker, %{"track_id" => Ecto.UUID.generate()})
  end

  test "cancels when no match is found" do
    track = insert(:track, tag_title: "Nope", norm_artist: "nobody")

    expect(Mock, :search_song, fn _term ->
      {:ok, %Response{data: [], quota_remaining: 999, status: 200}}
    end)

    assert {:cancel, :no_match} = perform_job(ResolveSongWorker, %{"track_id" => track.id})
  end
end
