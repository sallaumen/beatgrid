defmodule Beatgrid.Workers.UndoBatchWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true

  alias Beatgrid.Review
  alias Beatgrid.Workers.UndoBatchWorker

  test "undoes the batch and broadcasts the undone/failed tally" do
    Review.subscribe()
    batch_id = Uniq.UUID.uuid7()

    assert :ok = perform_job(UndoBatchWorker, %{batch_id: batch_id})

    assert_receive {:batch_undone, %{undone: 0, failed: 0}}
  end

  test "enqueue/1 inserts one job carrying the batch id" do
    batch_id = Uniq.UUID.uuid7()

    assert {:ok, %Oban.Job{}} = UndoBatchWorker.enqueue(batch_id)
    assert [job] = all_enqueued(worker: UndoBatchWorker)
    assert job.args["batch_id"] == batch_id
  end
end
