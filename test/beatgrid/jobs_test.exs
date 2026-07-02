defmodule Beatgrid.JobsTest do
  use Beatgrid.DataCase, async: false, oban: true

  alias Beatgrid.Jobs
  alias Beatgrid.Workers.DownloadWorker

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
end
