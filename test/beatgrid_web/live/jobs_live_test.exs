defmodule BeatgridWeb.JobsLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Workers.{AnalyzeWorker, DedupWorker, DownloadWorker, EnrichWorker}
  alias Beatgrid.Workers.RecommendWorker

  defp insert_job(args, state) do
    args
    |> DownloadWorker.new()
    |> Oban.insert!()
    |> Ecto.Changeset.change(state: state)
    |> Beatgrid.Repo.update!()
  end

  test "local imports and recordings lead back to their own workspace", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/jobs?worker=ImportWorker")

    assert has_element?(
             view,
             "#jobs-context-link[href='/importados?origem=local']",
             "Arquivos locais"
           )

    render_patch(view, ~p"/jobs?worker=MixDownloadWorker")
    assert has_element?(view, "#jobs-context-link[href='/sets-online']", "Sets gravados")
  end

  test "choosing the task type keeps the current status in the URL", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/jobs?state=failed")
    assert has_element?(view, "main h1", "Fila de tarefas")
    view |> form("#task-type", worker: "DownloadWorker") |> render_change()
    assert_patch(view, ~p"/jobs?state=failed&worker=DownloadWorker")
    assert has_element?(view, "#task-type option[selected]", "Baixar do YouTube")
    view |> form("#task-type", worker: "") |> render_change()
    assert_patch(view, ~p"/jobs?state=failed")
  end

  test "the active filter finds pending work hidden behind recent completed jobs", %{conn: conn} do
    active =
      for state <- ~w(available scheduled executing retryable suspended) do
        insert_job(%{"url" => "https://y/#{state}"}, state)
      end

    for index <- 1..100 do
      insert_job(%{"url" => "https://y/completed-#{index}"}, "completed")
    end

    discarded = insert_job(%{"url" => "https://y/discarded"}, "discarded")
    cancelled = insert_job(%{"url" => "https://y/cancelled"}, "cancelled")

    {:ok, view, _} = live(conn, ~p"/jobs?worker=DownloadWorker")

    for job <- active, do: refute(has_element?(view, "#job-#{job.id}"))
    view |> element("#job-state-groups a", "Em andamento") |> render_click()
    assert_patch(view, ~p"/jobs?state=active&worker=DownloadWorker")

    for job <- active, do: assert(has_element?(view, "#job-#{job.id}"))
    refute has_element?(view, "#job-#{discarded.id}")
    refute has_element?(view, "#job-#{cancelled.id}")
    refute has_element?(view, "#jobs-list li", "Concluída")
    assert has_element?(view, "#job-state-groups a[aria-current='true']", "Em andamento")

    view |> element("#job-state-phases a", "Executando") |> render_click()
    assert_patch(view, ~p"/jobs?state=executing&worker=DownloadWorker")
    [queued, _, executing, _, paused] = active
    assert has_element?(view, "#job-#{executing.id}")
    refute has_element?(view, "#job-#{queued.id}")
    assert has_element?(view, "#job-state-phases a[aria-current='true']", "Executando")

    view |> element("#job-state-groups a", "Em andamento") |> render_click()
    assert_patch(view, ~p"/jobs?state=active&worker=DownloadWorker")
    assert has_element?(view, "#job-#{queued.id}")
    assert has_element?(view, "#job-#{paused.id}", "Pausada")
  end

  test "the active filter updates when a job completes", %{conn: conn} do
    job = insert_job(%{"url" => "https://y/finishes"}, "executing")
    {:ok, view, _} = live(conn, ~p"/jobs?state=active")
    assert has_element?(view, "#job-#{job.id}", "Executando")

    job |> Ecto.Changeset.change(state: "completed") |> Beatgrid.Repo.update!()
    send(view.pid, :refresh)

    refute has_element?(view, "#job-#{job.id}")
    assert has_element?(view, "main", "Nenhuma tarefa em andamento neste filtro.")
    assert has_element?(view, "#job-state-groups a[aria-current='true']", "Em andamento")
  end

  test "failed and exact discarded filters keep their distinct scope and destination", %{
    conn: conn
  } do
    discarded = insert_job(%{"url" => "https://y/discarded"}, "discarded")
    cancelled = insert_job(%{"url" => "https://y/cancelled"}, "cancelled")
    {:ok, view, _} = live(conn, ~p"/jobs?state=failed&worker=DownloadWorker")

    assert has_element?(view, "#jobs-context-link[href='/importados']", "Importações")
    assert has_element?(view, "#job-#{discarded.id}")
    assert has_element?(view, "#job-#{cancelled.id}")
    assert has_element?(view, "button[phx-click=retry_all_failed][data-confirm*=canceladas]")

    view |> element("#job-state-phases a", "Descartada") |> render_click()
    assert_patch(view, ~p"/jobs?state=discarded&worker=DownloadWorker")
    assert has_element?(view, "#job-#{discarded.id}")
    refute has_element?(view, "#job-#{cancelled.id}")
    refute has_element?(view, "button[phx-click=retry_all_failed]")

    view |> form("#task-type", worker: "AnalyzeWorker") |> render_change()
    assert_patch(view, ~p"/jobs?state=discarded&worker=AnalyzeWorker")
    assert has_element?(view, "#jobs-context-link[href='/manutencao']", "Manutenção")
  end

  test "retry provides feedback after leaving failures, while cancel warns it does not undo work",
       %{
         conn: conn
       } do
    job = insert_job(%{"url" => "https://y/retry-from-failed"}, "discarded")
    {:ok, view, _} = live(conn, ~p"/jobs?state=failed&worker=DownloadWorker")

    view |> element("#job-#{job.id} button[phx-click=retry]") |> render_click()
    refute has_element?(view, "#job-#{job.id}")
    assert render(view) =~ "Acompanhe em andamento"

    view |> element("#job-state-groups a", "Em andamento") |> render_click()
    assert_patch(view, ~p"/jobs?state=active&worker=DownloadWorker")
    assert has_element?(view, "#job-#{job.id} button[phx-click=cancel][data-confirm*=desfaz]")

    view |> element("#job-#{job.id} button[phx-click=cancel]") |> render_click()
    refute has_element?(view, "#job-#{job.id}")
    assert Beatgrid.Repo.get(Oban.Job, job.id).state == "cancelled"
  end

  test "lists jobs with state and args, and a retry button for failed ones", %{conn: conn} do
    insert_job(%{"url" => "https://y/bad"}, "discarded")

    {:ok, _view, html} = live(conn, ~p"/jobs")

    assert html =~ "Fila de tarefas"
    # Worker module is rendered with a friendly PT action label AND the real
    # module name (a small mono tag), so the user gets both.
    assert html =~ "Baixar"
    assert html =~ "DownloadWorker"
    assert html =~ "https://y/bad"
    assert html =~ "Descartada"
    assert html =~ ~s(phx-click="retry")
  end

  test "the Painel deep-link shows only that worker's failures, with bulk actions", %{
    conn: conn
  } do
    insert_job(
      %{"url" => "https://y/dead", "title" => "Trio Nordestino - Forró Pesado"},
      "discarded"
    )

    insert_job(%{"url" => "https://y/alive"}, "available")

    %{} |> DedupWorker.new() |> Oban.insert!()

    {:ok, view, html} = live(conn, ~p"/jobs?state=failed&worker=DownloadWorker")

    # only the failed download shows — with its song title, so no more blind counts
    assert html =~ "Trio Nordestino - Forró Pesado"
    refute html =~ "https://y/alive"
    refute html =~ "biblioteca inteira"
    assert html =~ "Tentar todas novamente"

    view |> element("button[phx-click=retry_all_failed]") |> render_click()

    urls =
      Beatgrid.Jobs.list_recent(worker: "DownloadWorker", states: ["available"])
      |> Enum.map(& &1.args["url"])
      |> Enum.sort()

    assert urls == ["https://y/alive", "https://y/dead"]
  end

  test "clear_all_failed wipes the failure list", %{conn: conn} do
    insert_job(%{"url" => "https://y/dead"}, "cancelled")

    {:ok, view, _html} = live(conn, ~p"/jobs?state=failed&worker=DownloadWorker")
    view |> element("button[phx-click=clear_all_failed]") |> render_click()

    assert Beatgrid.Jobs.list_recent(worker: "DownloadWorker") == []
    refute render(view) =~ "https://y/dead"
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
    assert has_element?(view, "button[phx-click='toggle_details'][aria-expanded='true']")
  end

  test "scheduled jobs show a future time and the phase beside their subject", %{conn: conn} do
    job = insert_job(%{"url" => "https://y/later"}, "scheduled")

    job
    |> Ecto.Changeset.change(scheduled_at: DateTime.add(DateTime.utc_now(), 900, :second))
    |> Beatgrid.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/jobs")
    assert has_element?(view, "#job-#{job.id}", "Agendada")
    assert has_element?(view, "#job-#{job.id}", "daqui")
    refute has_element?(view, "#job-#{job.id}", "agora")
  end
end
