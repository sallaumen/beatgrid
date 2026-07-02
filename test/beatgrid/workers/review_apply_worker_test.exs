defmodule Beatgrid.Workers.ReviewApplyWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true

  alias Beatgrid.Review
  alias Beatgrid.Workers.ReviewApplyWorker

  test "applies the selected ids and broadcasts the batch result" do
    Review.subscribe()

    assert :ok = perform_job(ReviewApplyWorker, %{ids: []})

    assert_receive {:review_applied, %{batch_id: batch_id, applied: 0, failed: 0}}
    assert is_binary(batch_id)
  end

  test "enqueue/1 inserts one job carrying the ids" do
    assert {:ok, %Oban.Job{}} = ReviewApplyWorker.enqueue(["abc"])
    assert [job] = all_enqueued(worker: ReviewApplyWorker)
    assert job.args["ids"] == ["abc"]
  end
end
