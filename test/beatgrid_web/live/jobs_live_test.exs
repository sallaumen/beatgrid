defmodule BeatgridWeb.JobsLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Workers.{AnalyzeWorker, DownloadWorker, EnrichWorker, RecommendWorker}

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
    # Worker module is rendered with a friendly PT action label AND the real
    # module name (a small mono tag), so the user gets both.
    assert html =~ "Baixar"
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

  test "renders friendly PT labels for known workers", %{conn: conn} do
    %{"scope" => "pending", "batch_id" => "b1"}
    |> EnrichWorker.new()
    |> Oban.insert!()

    {:ok, _view, html} = live(conn, ~p"/jobs")

    assert html =~ "Enriquecer"
    assert html =~ "EnrichWorker"
  end

  test "RecommendWorker shows a friendly label, the real name, and a readable summary",
       %{conn: conn} do
    %{"scope" => "folder", "folder" => "forro_roots", "batch_id" => "b1"}
    |> RecommendWorker.new()
    |> Oban.insert!()

    {:ok, _view, html} = live(conn, ~p"/jobs")

    # Friendly action label (this worker was previously missing from the map and
    # rendered its bare module name).
    assert html =~ "Sugerir repertório"
    # The real module name is still shown (as a tag).
    assert html =~ "RecommendWorker"
    # The summary is human-readable (the folder label), not a dump of arg keys.
    assert html =~ "Forró Roots"
    refute html =~ "batch_id"
  end

  test "resolves the referenced track title in a job summary", %{conn: conn} do
    track = insert(:track, tag_title: "Asa Branca", status: :present)

    %{"track_id" => track.id}
    |> AnalyzeWorker.new()
    |> Oban.insert!()

    {:ok, _view, html} = live(conn, ~p"/jobs")

    assert html =~ "Analisar áudio"
    # The track title is resolved (one batched query), not shown as a bare UUID.
    assert html =~ "Asa Branca"
  end

  test "expand/collapse toggle shows full error details", %{conn: conn} do
    error = "ERRO_INICIO " <> String.duplicate("x", 200) <> " ERRO_FIM_TOKEN"
    job = insert_failed_job("https://y/expand-test", error)

    {:ok, view, html} = live(conn, ~p"/jobs")

    # Collapsed: long tail token must NOT be visible
    refute html =~ "ERRO_FIM_TOKEN"

    expanded_html =
      view
      |> element("button[phx-click='toggle_details'][phx-value-id='#{job.id}']")
      |> render_click()

    # Expanded: full error must now be visible
    assert expanded_html =~ "ERRO_FIM_TOKEN"
  end
end
