defmodule Beatgrid.Workers.EnrichWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  import Mox

  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Organization
  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.{ApiCall, Response}
  alias Beatgrid.Workers.EnrichWorker
  alias Beatgrid.YouTube

  defp song_attrs do
    %{
      sc_uuid: "u1",
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

  defp matching_track(attrs \\ []) do
    insert(
      :track,
      Keyword.merge(
        [
          status: :present,
          genre_folder: nil,
          soundcharts_song_id: nil,
          tag_artist: "Casuarina",
          tag_title: "Disritmia",
          norm_artist: "casuarina",
          norm_title: "disritmia",
          filename: "abc.mp3",
          rel_path: "_Inbox/abc.mp3"
        ],
        attrs
      )
    )
  end

  defp stub_resolve_match do
    expect(Beatgrid.Soundcharts.Mock, :search_song, fn _term ->
      {:ok,
       %Response{
         data: [%{uuid: "u1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}],
         quota_remaining: 999,
         status: 200
       }}
    end)

    expect(Beatgrid.Soundcharts.Mock, :get_song, fn "u1" ->
      {:ok, %Response{data: song_attrs(), quota_remaining: 998, status: 200}}
    end)
  end

  defp stub_ai do
    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "classifications" => [
           %{"index" => 1, "folder" => "mpb", "confidence" => 0.9, "rationale" => "r"}
         ],
         "resolutions" => [
           %{
             "index" => 1,
             "same_recording" => true,
             "artist" => "Casuarina",
             "title" => "Disritmia",
             "confidence" => 0.9,
             "rationale" => "ok"
           }
         ]
       }}
    end)
  end

  setup do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "d")
    :ok
  end

  test "scope track broadcasts running then done and creates review suggestions" do
    track = matching_track()
    stub_resolve_match()
    stub_ai()

    YouTube.subscribe_enrich()

    assert :ok =
             perform_job(EnrichWorker, %{
               "scope" => "track",
               "id" => track.id,
               "batch_id" => "b1"
             })

    track_id = track.id
    assert_receive {:enrich_progress, %{status: :running, scope: "track", id: ^track_id}}

    assert_receive {:enrich_progress,
                    %{status: :done, scope: "track", id: ^track_id, resolved: 1} = done}

    assert done.budget_exhausted == false
    assert done.total == 1

    assert Tracks.get(track.id).soundcharts_song_id
    assert [_rename] = NameSync.list_by(status: :pending)
    assert [move] = Organization.list_by(status: :pending, source: :claude)
    assert move.track_id == track.id
  end

  test "scope pending enriches all pending tracks and reports total" do
    t1 = matching_track(filename: "a.mp3", rel_path: "_Inbox/a.mp3")
    t2 = matching_track(filename: "b.mp3", rel_path: "_Inbox/b.mp3")

    # Two resolutions (one per track) for the two-track batch.
    stub_resolve_match()
    stub_resolve_match()
    stub_ai()

    YouTube.subscribe_enrich()

    assert :ok = perform_job(EnrichWorker, %{"scope" => "pending", "batch_id" => "b2"})

    assert_receive {:enrich_progress, %{status: :running, scope: "pending", total: 2, done: 0}}

    assert_receive {:enrich_progress,
                    %{status: :done, scope: "pending", total: 2, done: 2} = done}

    assert done.budget_exhausted == false

    assert Tracks.get(t1.id).soundcharts_song_id
    assert Tracks.get(t2.id).soundcharts_song_id
  end

  test "budget exhausted returns :ok, halts further calls, and flags the final broadcast" do
    # Drive the budget below the floor via the DB header ONLY — NOT a global
    # Application.put_env(:beatgrid, Soundcharts, ...). request_cap/budget_floor are
    # global config; mutating them here leaked into concurrent async tests (their
    # check_budget read the tiny cap), making SoundchartsTest flake. A recorded
    # quota_remaining of 0 makes check_budget refuse (0 > floor is false) and is
    # fully isolated to this test's sandbox transaction.
    %ApiCall{}
    |> ApiCall.changeset(%{
      provider: "soundcharts",
      endpoint: "song/get",
      success: true,
      quota_remaining: 0,
      occurred_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
    |> Repo.insert!()

    track = matching_track()

    # No Mox expectations on Soundcharts — if a call leaked past the halt, the
    # Mock would raise. (AI is never reached because nothing is processed.)
    YouTube.subscribe_enrich()

    assert :ok =
             perform_job(EnrichWorker, %{
               "scope" => "track",
               "id" => track.id,
               "batch_id" => "b3"
             })

    assert_receive {:enrich_progress, %{status: :done, budget_exhausted: true, done: 0}}

    refute Tracks.get(track.id).soundcharts_song_id
    assert NameSync.list_by(status: :pending) == []
    assert Organization.list_by(status: :pending, source: :claude) == []
  end
end
