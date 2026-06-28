defmodule Beatgrid.YouTubeTest do
  # async: false — ingest overrides the global :library_root and writes files.
  use Beatgrid.DataCase, async: false, oban: true

  import Mox

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Organization
  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.{ApiCall, Response}
  alias Beatgrid.Workers.DownloadWorker
  alias Beatgrid.YouTube

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  defp stub_metadata do
    stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
      {:ok, %Metadata{duration_ms: 1000, bitrate_kbps: 128}}
    end)
  end

  defp expect_download(title) do
    expect(Beatgrid.YouTube.DownloaderMock, :download, fn _url, dest ->
      path = Path.join(dest, "abc.mp3")
      File.write!(path, "audio")
      {:ok, [%{path: path, title: title, url: "https://y/abc"}]}
    end)
  end

  defp expect_download_full(title, views, upload) do
    expect(Beatgrid.YouTube.DownloaderMock, :download, fn _url, dest ->
      path = Path.join(dest, "abc.mp3")
      File.write!(path, "audio")

      {:ok,
       [%{path: path, title: title, url: "https://y/abc", views: views, upload_date: upload}]}
    end)
  end

  @tag :tmp_dir
  test "download_and_ingest creates an _Inbox track with the parsed title" do
    stub_metadata()
    expect_download("Djavan - Sina (Official Video)")

    assert {:ok, 1} = YouTube.download_and_ingest("https://y/abc")

    t = Tracks.get_by_path("_Inbox/abc.mp3")
    assert t.tag_artist == "Djavan"
    assert t.tag_title == "Sina"
    assert t.norm_title == "sina"
    assert t.source_playlist == "youtube"
    assert t.status == :present
    assert t.raw_tags["youtube_url"] == "https://y/abc"
  end

  @tag :tmp_dir
  test "DownloadWorker downloads, ingests and reports :ok" do
    stub_metadata()
    expect_download("Luiz Gonzaga - Asa Branca")

    assert :ok = perform_job(DownloadWorker, %{"url" => "https://y/abc"})
    assert Tracks.get_by_path("_Inbox/abc.mp3").tag_artist == "Luiz Gonzaga"
  end

  test "enqueue schedules one ExpandWorker per non-blank URL line" do
    assert {:ok, 2} = YouTube.enqueue("https://y/1\n\n  https://y/2  \n")

    urls =
      all_enqueued(worker: Beatgrid.Workers.ExpandWorker)
      |> Enum.map(& &1.args["url"])
      |> Enum.sort()

    assert urls == ["https://y/1", "https://y/2"]
  end

  @tag :tmp_dir
  test "download_and_ingest records the source playlist URL when given one" do
    stub_metadata()
    expect_download("Djavan - Sina (Official Video)")

    assert {:ok, 1} = YouTube.download_and_ingest("https://y/abc", "https://y/playlist")

    t = Tracks.get_by_path("_Inbox/abc.mp3")
    assert t.raw_tags["youtube_playlist_url"] == "https://y/playlist"
    assert t.raw_tags["youtube_url"] == "https://y/abc"
  end

  test "pending_count counts only downloaded-but-unenriched tracks" do
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)
    song = insert(:soundcharts_song)
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: song.id)
    insert(:track, status: :present, genre_folder: "mpb")

    assert YouTube.pending_count() == 1
  end

  @tag :tmp_dir
  test "ingest persiste views/data e marca candidato Ouro quando sem ISRC" do
    stub_metadata()
    expect_download_full("Raridade - Forró de Antigamente", 250, "20120607")

    assert {:ok, 1} = YouTube.download_and_ingest("https://y/abc")

    t = Tracks.get_by_path("_Inbox/abc.mp3")
    assert t.youtube_views == 250
    assert t.youtube_published_at == ~D[2012-06-07]
    assert t.gold_status == :candidate
  end

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

  test "enrich_pending resolves pending tracks and creates review suggestions" do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "d")

    track =
      insert(:track,
        status: :present,
        genre_folder: nil,
        soundcharts_song_id: nil,
        tag_artist: "Casuarina",
        tag_title: "Disritmia",
        norm_artist: "casuarina",
        norm_title: "disritmia",
        filename: "abc.mp3",
        rel_path: "_Inbox/abc.mp3"
      )

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

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "classifications" => [
           %{"index" => 1, "folder" => "mpb", "confidence" => 0.6, "rationale" => "r"}
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

    assert {:ok, %{enriched: 1, resolved: 1}} = YouTube.enrich_pending()

    assert Tracks.get(track.id).soundcharts_song_id
    assert [_rename] = NameSync.list_by(status: :pending)
    assert [move] = Organization.list_by(status: :pending, source: :claude)
    assert move.track_id == track.id
  end

  test "enrich_pending with nothing to do makes no external calls" do
    assert {:ok, %{enriched: 0, resolved: 0}} = YouTube.enrich_pending()
  end

  test "expand_and_enqueue lists videos and enqueues one DownloadWorker each (playlist)" do
    expect(Beatgrid.YouTube.DownloaderMock, :list_entries, fn "https://y/playlist" ->
      {:ok,
       [
         %{id: "a", title: "A", url: "https://y/a"},
         %{id: "b", title: "B", url: "https://y/b"}
       ]}
    end)

    assert {:ok, 2} = YouTube.expand_and_enqueue("https://y/playlist")

    jobs = all_enqueued(worker: DownloadWorker)
    assert length(jobs) == 2
    a = Enum.find(jobs, &(&1.args["url"] == "https://y/a"))
    assert a.args["playlist_url"] == "https://y/playlist"
    assert a.args["video_id"] == "a"
  end

  test "expand_and_enqueue sets no playlist_url for a single video" do
    expect(Beatgrid.YouTube.DownloaderMock, :list_entries, fn _ ->
      {:ok, [%{id: "solo", title: "Solo", url: "https://y/solo"}]}
    end)

    assert {:ok, 1} = YouTube.expand_and_enqueue("https://y/solo")
    [job] = all_enqueued(worker: DownloadWorker)
    assert job.args["playlist_url"] == nil
  end

  test "expand_and_enqueue surfaces an empty expansion as an error" do
    expect(Beatgrid.YouTube.DownloaderMock, :list_entries, fn _ -> {:ok, []} end)

    assert {:error, :no_entries} = YouTube.expand_and_enqueue("https://y/empty")
    assert all_enqueued(worker: Beatgrid.Workers.DownloadWorker) == []
  end

  test "enrich_track resolves one track on demand and creates review suggestions" do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "d")

    track =
      insert(:track,
        status: :present,
        genre_folder: nil,
        soundcharts_song_id: nil,
        tag_artist: "Casuarina",
        tag_title: "Disritmia",
        norm_artist: "casuarina",
        norm_title: "disritmia",
        filename: "abc.mp3",
        rel_path: "_Inbox/abc.mp3"
      )

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

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "classifications" => [
           %{"index" => 1, "folder" => "mpb", "confidence" => 0.6, "rationale" => "r"}
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

    assert {:ok, %{resolved: true}} = YouTube.enrich_track(track.id)

    assert Tracks.get(track.id).soundcharts_song_id
    assert [_rename] = NameSync.list_by(status: :pending)
    assert [move] = Organization.list_by(status: :pending, source: :claude)
    assert move.track_id == track.id
  end

  @tag :tmp_dir
  test "no_match carimba sc_attempted_at" do
    track = insert(:track, tag_artist: "Ninguém", tag_title: "Inédita", norm_artist: "ninguem")

    expect(Beatgrid.Soundcharts.Mock, :search_song, fn _ ->
      {:ok, %Beatgrid.Soundcharts.Response{data: [], quota_remaining: 999, status: 200}}
    end)

    assert :no_match = YouTube.resolve_track_enrich(track.id)
    assert Tracks.get(track.id).sc_attempted_at
  end

  @tag :tmp_dir
  test "enrich confirma Ouro quando Soundcharts não acha" do
    track = insert(:track, tag_artist: "Ninguém", tag_title: "Inédita", norm_artist: "ninguem")

    expect(Beatgrid.Soundcharts.Mock, :search_song, fn _term ->
      {:ok, %Response{data: [], quota_remaining: 999, status: 200}}
    end)

    assert :no_match = YouTube.resolve_track_enrich(track.id)
    assert Tracks.get(track.id).gold_status == :confirmed
  end

  @tag :tmp_dir
  test "enrich rebaixa candidato quando Soundcharts acha" do
    track =
      insert(:track,
        gold_status: :candidate,
        tag_artist: "Casuarina",
        tag_title: "Disritmia",
        norm_artist: "casuarina"
      )

    expect(Beatgrid.Soundcharts.Mock, :search_song, fn _term ->
      {:ok,
       %Response{
         data: [%{uuid: "u1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}],
         quota_remaining: 999,
         status: 200
       }}
    end)

    expect(Beatgrid.Soundcharts.Mock, :get_song, fn "u1" ->
      {:ok,
       %Response{
         data: song_attrs(),
         quota_remaining: 998,
         status: 200
       }}
    end)

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
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

    assert :resolved = YouTube.resolve_track_enrich(track.id)
    assert is_nil(Tracks.get(track.id).gold_status)
  end

  test "enrich_track returns {:error, :budget_exhausted} and creates no suggestions" do
    # Drive the budget below the floor via the DB header ONLY — NOT a global
    # Application.put_env(:beatgrid, Soundcharts, ...). request_cap/budget_floor are
    # global config; mutating them here leaked into concurrent async tests (their
    # check_budget read the tiny cap), making SoundchartsTest/ResolveSongWorkerTest
    # flake intermittently. A recorded quota_remaining of 0 makes check_budget refuse
    # (0 > floor is false for any floor) and is fully isolated to this test's sandbox.
    %ApiCall{}
    |> ApiCall.changeset(%{
      provider: "soundcharts",
      endpoint: "song/get",
      success: true,
      quota_remaining: 0,
      occurred_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
    |> Repo.insert!()

    track =
      insert(:track,
        status: :present,
        genre_folder: nil,
        soundcharts_song_id: nil,
        tag_title: "Anything"
      )

    # No Mox expectations — if the guard let a call through, Mock would raise.
    assert {:error, :budget_exhausted} = YouTube.enrich_track(track.id)

    # No suggestions should have been created.
    assert NameSync.list_by(status: :pending) == []
    assert Organization.list_by(status: :pending, source: :claude) == []
  end

  test "baldes: pending = nunca tentadas; rare = tentadas-sem-match não arquivadas" do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    never = insert(:track, status: :present, soundcharts_song_id: nil, genre_folder: nil)

    rare =
      insert(:track,
        status: :present,
        soundcharts_song_id: nil,
        genre_folder: nil,
        sc_attempted_at: now
      )

    assert YouTube.pending_count() == 1
    assert YouTube.pending_ids() == [never.id]
    assert YouTube.rare_unfiled_count() == 1
    assert YouTube.rare_unfiled_ids() == [rare.id]
  end
end
