defmodule Beatgrid.Workers.MoveBatchWorkerTest do
  # async: false — moves files on disk under an overridden :library_root and the
  # genre-tag write goes through the globally stubbed Tagging mock.
  use Beatgrid.DataCase, async: false, oban: true

  import Mox

  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Workers.MoveBatchWorker

  setup :set_mox_global
  setup :isolate_library_root

  @tag :tmp_dir
  test "moves the batch on disk and broadcasts the result", %{tmp_dir: root} do
    stub(Beatgrid.Tagging.Mock, :write_genre, fn _path, _genre -> :ok end)
    insert(:genre_folder, key: "forro", display_name: "Forró", dir_name: "Forró")
    File.mkdir_p!(Path.join(root, "MPB"))
    File.write!(Path.join(root, "MPB/a.mp3"), "a")

    track =
      insert(:track,
        status: :present,
        rel_path: "MPB/a.mp3",
        filename: "a.mp3",
        genre_folder: "mpb"
      )

    Library.subscribe_import()

    assert :ok = perform_job(MoveBatchWorker, %{ids: [track.id], folder: "forro"})

    assert_receive {:tracks_moved, %{moved: 1, failed: 0, batch_id: batch_id}}
    assert is_binary(batch_id)
    assert Tracks.get(track.id).genre_folder == "forro"
    assert File.exists?(Path.join(root, "Forró/a.mp3"))
  end

  test "enqueue/2 inserts one job carrying ids and folder" do
    assert {:ok, %Oban.Job{}} = MoveBatchWorker.enqueue(["id-1"], "forro")
    assert [job] = all_enqueued(worker: MoveBatchWorker)
    assert job.args["ids"] == ["id-1"]
    assert job.args["folder"] == "forro"
  end
end
