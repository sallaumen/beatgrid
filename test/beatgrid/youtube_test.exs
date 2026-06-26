defmodule Beatgrid.YouTubeTest do
  # async: false — ingest overrides the global :library_root and writes files.
  use Beatgrid.DataCase, async: false, oban: true

  import Mox

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library.Tracks
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
end
