defmodule Beatgrid.Workers.ReResolveWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  import Mox
  import Beatgrid.Factory

  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Review
  alias Beatgrid.Soundcharts.{Mock, Response}
  alias Beatgrid.Workers.ReResolveWorker

  setup :verify_on_exit!

  defp song_attrs do
    %{
      sc_uuid: "uuid-1",
      name: "Disritmia",
      credit_name: "Casuarina",
      isrc: "BRKMM0900046",
      release_date: ~D[2010-01-05],
      genres: [],
      tempo_bpm: 120.0,
      music_key: 11,
      music_mode: 0,
      energy: 0.6,
      raw: %{}
    }
  end

  defp flagged_suggestion do
    {:ok, _} = NameSync.propose()
    [s] = NameSync.list_by(status: :pending)
    {:ok, flagged} = NameSync.set_reason(s, "[audit:wrong_song] suspect")
    flagged
  end

  test "matches: rejects the suspect, re-proposes, and broadcasts :resolved" do
    wrong = insert(:soundcharts_song, credit_name: "Wrong", name: "Song")

    track =
      insert(:track,
        tag_title: "Disritmia",
        tag_artist: "Casuarina",
        norm_title: "disritmia",
        norm_artist: "casuarina",
        filename: "old.mp3",
        rel_path: "MPB/old.mp3",
        soundcharts_song_id: wrong.id,
        sc_match_confidence: :low
      )

    flagged = flagged_suggestion()

    expect(Mock, :search_song, fn _term ->
      {:ok,
       %Response{
         data: [%{uuid: "uuid-1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}],
         quota_remaining: 999,
         status: 200
       }}
    end)

    expect(Mock, :get_song, fn "uuid-1" ->
      {:ok, %Response{data: song_attrs(), quota_remaining: 998, status: 200}}
    end)

    Review.subscribe()

    assert :ok = perform_job(ReResolveWorker, %{"suggestion_id" => flagged.id})

    sid = flagged.id
    assert_receive {:re_resolve_done, %{suggestion_id: ^sid, outcome: :resolved}}

    assert NameSync.get(flagged.id).status == :rejected
    assert Tracks.get_with_song(track.id).soundcharts_song.credit_name == "Casuarina"
    assert [fresh] = NameSync.list_by(status: :pending)
    assert fresh.to_filename == "Casuarina - Disritmia.mp3"
  end

  test "no match: rejects the suspect and broadcasts :no_match" do
    wrong = insert(:soundcharts_song, credit_name: "Wrong", name: "Song")

    track =
      insert(:track,
        tag_title: "Obscure",
        tag_artist: "Nobody",
        norm_title: "obscure",
        norm_artist: "nobody",
        filename: "old.mp3",
        rel_path: "MPB/old.mp3",
        soundcharts_song_id: wrong.id,
        sc_match_confidence: :low
      )

    flagged = flagged_suggestion()

    expect(Mock, :search_song, fn _term ->
      {:ok, %Response{data: [], quota_remaining: 999, status: 200}}
    end)

    Review.subscribe()

    assert :ok = perform_job(ReResolveWorker, %{"suggestion_id" => flagged.id})

    assert_receive {:re_resolve_done, %{outcome: :no_match}}
    assert NameSync.get(flagged.id).status == :rejected
    assert Tracks.get(track.id).soundcharts_song_id == nil
  end

  test "cancels when the suggestion no longer exists" do
    assert {:cancel, :not_found} =
             perform_job(ReResolveWorker, %{"suggestion_id" => Ecto.UUID.generate()})
  end
end
