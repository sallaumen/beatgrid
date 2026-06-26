defmodule Beatgrid.YouTubeTest do
  # async: false — ingest overrides the global :library_root and writes files.
  use Beatgrid.DataCase, async: false, oban: true

  import Mox

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Organization
  alias Beatgrid.Soundcharts.Response
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

  test "enqueue schedules one job per non-blank URL line" do
    assert {:ok, 2} = YouTube.enqueue("https://y/1\n\n  https://y/2  \n")

    urls = all_enqueued(worker: DownloadWorker) |> Enum.map(& &1.args["url"]) |> Enum.sort()
    assert urls == ["https://y/1", "https://y/2"]
  end

  test "pending_count counts only downloaded-but-unenriched tracks" do
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)
    song = insert(:soundcharts_song)
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: song.id)
    insert(:track, status: :present, genre_folder: "mpb")

    assert YouTube.pending_count() == 1
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

    expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "classifications" => [
           %{"index" => 1, "folder" => "mpb", "confidence" => 0.9, "rationale" => "r"}
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
end
