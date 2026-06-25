defmodule Beatgrid.Workers.DedupWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  alias Beatgrid.Dedup
  alias Beatgrid.Workers.DedupWorker

  test "perform/1 detects duplicate groups" do
    insert(:track, content_sha256: "abc", rel_path: "a.mp3")
    insert(:track, content_sha256: "abc", rel_path: "b.mp3")

    assert :ok = perform_job(DedupWorker, %{})
    assert length(Dedup.list_groups()) == 1
  end

  test "enqueue/0 inserts a dedup job" do
    assert {:ok, %Oban.Job{}} = DedupWorker.enqueue()
    assert_enqueued(worker: DedupWorker)
  end
end
