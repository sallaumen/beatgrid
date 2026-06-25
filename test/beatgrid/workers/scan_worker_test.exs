defmodule Beatgrid.Workers.ScanWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Workers.ScanWorker

  @tag :tmp_dir
  test "perform/1 scans the given root", %{tmp_dir: root} do
    File.write!(Path.join(root, "a.mp3"), "data")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
      {:ok, %Metadata{title: "A", artist: "B", bitrate_kbps: 320, duration_ms: 200_000}}
    end)

    assert :ok = perform_job(ScanWorker, %{"root" => root, "mark_missing" => false})
    assert Tracks.count() == 1
  end

  test "enqueue/1 inserts a scan job carrying the root" do
    assert {:ok, %Oban.Job{}} = ScanWorker.enqueue(root: "/tmp/somewhere", mark_missing: false)
    assert_enqueued(worker: ScanWorker, args: %{"root" => "/tmp/somewhere"})
  end
end
