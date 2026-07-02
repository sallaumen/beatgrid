defmodule Beatgrid.JobsTest do
  use Beatgrid.DataCase, async: false, oban: true

  alias Beatgrid.Jobs
  alias Beatgrid.Workers.{DedupWorker, DownloadWorker}

  defp insert_job(args, state \\ "available") do
    args
    |> DownloadWorker.new()
    |> Oban.insert!()
    |> Ecto.Changeset.change(state: state)
    |> Beatgrid.Repo.update!()
  end

  test "list_recent returns jobs newest-first" do
    _old = insert_job(%{url: "https://y/1"})
    new = insert_job(%{url: "https://y/2"})

    assert [first, _] = Jobs.list_recent()
    assert first.id == new.id
    assert first.args == %{"url" => "https://y/2"}
  end

  test "list_recent filters by state" do
    insert_job(%{url: "https://y/ok"}, "completed")
    insert_job(%{url: "https://y/bad"}, "discarded")

    states = Jobs.list_recent(states: ["discarded"]) |> Enum.map(& &1.state)
    assert states == ["discarded"]
  end

  test "list_recent filters by worker short name" do
    insert_job(%{url: "https://y/dl"}, "discarded")

    %{}
    |> DedupWorker.new()
    |> Oban.insert!()

    assert [only] = Jobs.list_recent(worker: "DownloadWorker")
    assert only.worker == "Beatgrid.Workers.DownloadWorker"
    assert Jobs.list_recent(worker: "DedupWorker") |> length() == 1
  end

  test "retry_failed re-queues and clear_failed deletes only terminal jobs" do
    insert_job(%{url: "https://y/keep"}, "available")
    insert_job(%{url: "https://y/dead1"}, "discarded")
    insert_job(%{url: "https://y/dead2"}, "cancelled")

    assert Jobs.retry_failed("DownloadWorker") == 2
    assert Jobs.list_recent(states: ["discarded", "cancelled"]) == []

    [j_1, j_2] = Jobs.list_recent(states: ["available"], worker: "DownloadWorker") |> Enum.take(2)
    assert j_1.state == "available" and j_2.state == "available"
  end

  test "clear_failed removes the failure rows without touching live jobs" do
    live = insert_job(%{url: "https://y/live"}, "executing")
    insert_job(%{url: "https://y/dead"}, "discarded")

    assert Jobs.clear_failed("DownloadWorker") == 1

    assert [only] = Jobs.list_recent(worker: "DownloadWorker")
    assert only.id == live.id
  end
end
