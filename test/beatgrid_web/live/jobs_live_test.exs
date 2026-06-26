defmodule BeatgridWeb.JobsLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest

  alias Beatgrid.Workers.DownloadWorker

  defp insert_job(args, state) do
    args
    |> DownloadWorker.new()
    |> Oban.insert!()
    |> Ecto.Changeset.change(state: state)
    |> Beatgrid.Repo.update!()
  end

  test "lists jobs with state and args, and a retry button for failed ones", %{conn: conn} do
    insert_job(%{"url" => "https://y/bad"}, "discarded")

    {:ok, _view, html} = live(conn, ~p"/jobs")

    assert html =~ "Jobs"
    assert html =~ "DownloadWorker"
    assert html =~ "https://y/bad"
    assert html =~ "Descartada"
    assert html =~ ~s(phx-click="retry")
  end

  test "retry transitions a discarded job back to available", %{conn: conn} do
    job = insert_job(%{"url" => "https://y/bad"}, "discarded")

    {:ok, view, _html} = live(conn, ~p"/jobs")
    view |> element("button[phx-value-id='#{job.id}'][phx-click='retry']") |> render_click()

    assert Beatgrid.Repo.get(Oban.Job, job.id).state == "available"
  end
end
