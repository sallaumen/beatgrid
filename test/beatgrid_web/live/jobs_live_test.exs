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

  defp insert_failed_job(url, error) do
    job =
      %{"url" => url}
      |> DownloadWorker.new()
      |> Oban.insert!()

    job
    |> Ecto.Changeset.change(
      state: "discarded",
      errors: [%{"attempt" => 1, "at" => "2026-06-26T00:00:00Z", "error" => error}]
    )
    |> Beatgrid.Repo.update!()
  end

  test "expand/collapse toggle shows full error details", %{conn: conn} do
    error = "ERRO_INICIO " <> String.duplicate("x", 200) <> " ERRO_FIM_TOKEN"
    job = insert_failed_job("https://y/expand-test", error)

    {:ok, view, html} = live(conn, ~p"/jobs")

    # Collapsed: long tail token must NOT be visible
    refute html =~ "ERRO_FIM_TOKEN"

    # Click the toggle button for this job
    expanded_html =
      view
      |> element("button[phx-click='toggle_details'][phx-value-id='#{job.id}']")
      |> render_click()

    # Expanded: full error must now be visible
    assert expanded_html =~ "ERRO_FIM_TOKEN"
  end
end
