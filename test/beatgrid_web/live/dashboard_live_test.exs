defmodule BeatgridWeb.DashboardLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  alias Beatgrid.Analysis
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Repertoire
  alias Beatgrid.Workers.{ExpandWorker, RecommendWorker}

  setup :isolate_library_root

  test "collection overview precedes recommendations and the page offers a direct jump", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/painel")
    assert has_element?(view, "a[href='#dashboard-gaps']", "Lacunas")
    assert has_element?(view, "#dashboard-kpis dl")
    {insights, _} = :binary.match(html, ~s(id="dashboard-insights"))
    {gaps, _} = :binary.match(html, ~s(id="dashboard-gaps"))
    assert insights < gaps
  end

  test "renders the repertoire overview and recommendations", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/painel")

    assert html =~ ~s(id="dashboard-kpis")
    assert html =~ ~s(id="dashboard-insights")
    assert html =~ ~s(id="dashboard-gaps")
  end

  test "shows headline KPIs and the genre / artist distributions", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    insert(:track,
      status: :present,
      genre_folder: "mpb",
      tag_artist: "Jobim",
      soundcharts_song: build(:soundcharts_song, tempo_bpm: 120.0, release_date: ~D[1975-03-01]),
      sc_match_confidence: :high
    )

    insert(:track, status: :present, genre_folder: "mpb", tag_artist: "Gil")

    {:ok, _view, html} = live(conn, ~p"/painel")

    assert html =~ "Repertório"
    assert html =~ "Total"
    assert html =~ "Resolvidas"
    assert html =~ "MPB"
    assert html =~ "Jobim"
    assert html =~ "1970s"
  end

  test "opens a genre's saved gaps directly from its distribution and keeps that scope in the URL",
       %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", sort_order: 1)
    insert(:genre_folder, key: "roots", display_name: "Roots", dir_name: "Roots", sort_order: 2)
    insert(:track, status: :present, genre_folder: "roots")

    insert(:recommendation,
      artist: "Elis Regina",
      song: "Águas de Março",
      genre_folder: "mpb",
      source: :gaps,
      status: :new
    )

    insert(:recommendation,
      artist: "Trio Nordestino",
      song: "Forró Pesado",
      genre_folder: "roots",
      source: :gaps,
      status: :new
    )

    insert(:recommendation,
      artist: "Luiz Gonzaga",
      song: "Asa Branca",
      genre_folder: "roots",
      source: :gaps,
      status: :imported
    )

    {:ok, view, _} = live(conn, ~p"/painel")

    path = ~p"/painel?genero=roots" <> "#dashboard-gaps"

    view
    |> element("#dashboard-genres a[href='#{path}']", "Lacunas")
    |> render_click()

    assert_patch(view, ~p"/painel?genero=roots")
    assert has_element?(view, "#gaps-scope", "Roots")
    assert has_element?(view, "#gaps-pending", "Forró Pesado")
    refute has_element?(view, "#gaps-pending", "Asa Branca")
    assert has_element?(view, "#gaps-imported", "Asa Branca")
    refute has_element?(view, "#gaps-pending", "Águas de Março")

    view |> element("button[phx-value-folder=mpb]") |> render_click()
    assert_patch(view, ~p"/painel?genero=mpb")
    assert has_element?(view, "#gaps-pending", "Águas de Março")

    # Back/forward or a fresh opening honours the folder encoded in the URL.
    render_patch(view, ~p"/painel?genero=roots")
    assert has_element?(view, "button[phx-value-folder=roots][aria-pressed=true]")
    {:ok, reopened, _} = live(conn, ~p"/painel?genero=roots")
    assert has_element?(reopened, "#gaps-pending", "Forró Pesado")
  end

  test "offline tempo appears on mount and refreshes while repertoire is open", %{conn: conn} do
    for bpm <- [114.8, 115.0, 118.0], do: insert(:track, bpm_detected: bpm)
    track = insert(:track)
    {:ok, view, _html} = live(conn, ~p"/painel")

    assert has_element?(
             view,
             "#dashboard-tempo li[aria-label='De 110 a menos de 115 BPM, 1 faixa']"
           )

    assert has_element?(
             view,
             "#dashboard-tempo li[aria-label='De 115 a menos de 120 BPM, 2 faixas']"
           )

    refute has_element?(
             view,
             "#dashboard-tempo li[aria-label='De 120 a menos de 125 BPM, 1 faixa']"
           )

    {:ok, _track} = Tracks.update(track, %{bpm_detected: 121.0})
    Analysis.broadcast_tick()

    assert has_element?(
             view,
             "#dashboard-tempo li[aria-label='De 120 a menos de 125 BPM, 1 faixa']"
           )
  end

  test "renders persisted repertoire gaps for the selected folder on mount", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    insert(:recommendation,
      artist: "Elis Regina",
      song: "Águas de Março",
      reason: "essencial MPB",
      genre_folder: "mpb",
      source: :gaps,
      status: :new
    )

    {:ok, _view, html} = live(conn, ~p"/painel")

    assert html =~ "Lacunas no repertório (IA)"
    assert html =~ "Elis Regina"
    assert html =~ "Águas de Março"
    assert html =~ "essencial MPB"
  end

  test "clicking Buscar lacunas enqueues a folder RecommendWorker", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    {:ok, view, _html} = live(conn, ~p"/painel")
    html = view |> element("button[phx-click=fetch_gaps]") |> render_click()

    assert_enqueued(worker: RecommendWorker, args: %{scope: "folder", folder: "mpb"})
    assert html =~ "Gerando…"
  end

  test "changing folders and revisiting the dashboard show which search is in flight", %{
    conn: conn
  } do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", sort_order: 1)
    insert(:genre_folder, key: "roots", display_name: "Roots", dir_name: "Roots", sort_order: 2)
    {:ok, view, _html} = live(conn, ~p"/painel")
    view |> element("button[phx-click=fetch_gaps]") |> render_click()

    view |> element("button[phx-value-folder=roots]") |> render_click()
    refute has_element?(view, "button[phx-click=fetch_gaps][disabled]")

    view |> element("button[phx-value-folder=mpb]") |> render_click()
    assert has_element?(view, "button[phx-click=fetch_gaps][disabled]", "Gerando")

    {:ok, reopened, _html} = live(conn, ~p"/painel")
    assert has_element?(reopened, "button[phx-click=fetch_gaps][disabled]", "Gerando")
  end

  test "completion and failure for another folder do not interrupt the current search", %{
    conn: conn
  } do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", sort_order: 1)
    insert(:genre_folder, key: "roots", display_name: "Roots", dir_name: "Roots", sort_order: 2)
    insert(:track, status: :present, genre_folder: "roots")
    {:ok, view, _html} = live(conn, ~p"/painel")
    view |> element("button[phx-click=fetch_gaps]") |> render_click()

    insert(:recommendation, genre_folder: "roots", source: :gaps, status: :new)

    for status <- [:done, :error] do
      Repertoire.broadcast_recommend(%{
        scope: "folder",
        key: "roots",
        status: status,
        count: 0,
        batch_id: Ecto.UUID.generate()
      })

      assert has_element?(view, "button[phx-click=fetch_gaps][disabled]", "Gerando")
      refute has_element?(view, "#flash-error")
    end

    assert has_element?(
             view,
             "#dashboard-genres a[aria-label='Lacunas de Roots: 1 sugestão salva']"
           )

    assert has_element?(
             view,
             "button[phx-value-folder=roots][aria-label='Roots: 1 sugestão salva']"
           )

    assert has_element?(view, "button[phx-value-folder=mpb][aria-pressed=true]")

    Repertoire.broadcast_recommend(%{
      scope: "folder",
      key: "mpb",
      status: :error,
      count: 0,
      batch_id: Ecto.UUID.generate()
    })

    assert has_element?(view, "#flash-error", "A busca de sugestões falhou")
    refute has_element?(view, "button[phx-click=fetch_gaps][disabled]")
  end

  test "a recommend-progress :done event reloads the persisted gaps live", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    {:ok, view, _html} = live(conn, ~p"/painel")
    refute render(view) =~ "Gilberto Gil"

    insert(:recommendation,
      artist: "Gilberto Gil",
      song: "Aquele Abraço",
      reason: "mesmo período",
      genre_folder: "mpb",
      source: :gaps,
      status: :new
    )

    send(
      view.pid,
      {:recommend_progress,
       %{batch_id: "b1", scope: "folder", key: "mpb", status: :done, count: 1}}
    )

    assert render(view) =~ "Gilberto Gil"
  end

  test "a suggested track opens a version review without importing", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    rec =
      insert(:recommendation,
        artist: "Tim Maia",
        song: "Azul da Cor do Mar",
        youtube_query: "Tim Maia Azul da Cor do Mar",
        genre_folder: "mpb",
        source: :gaps,
        status: :new
      )

    {:ok, view, _html} = live(conn, ~p"/painel")
    assert has_element?(view, "a[href='/importados?recomendacao=#{rec.id}']", "Conferir versões")
    refute_enqueued(worker: ExpandWorker)
    assert Repertoire.get_recommendation(rec.id).status == :new
  end

  test "pending gaps prioritize version review while imported gaps keep their options in history",
       %{
         conn: conn
       } do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    pending = insert(:recommendation, genre_folder: "mpb", source: :gaps, status: :new)
    imported = insert(:recommendation, genre_folder: "mpb", source: :gaps, status: :imported)

    {:ok, view, _html} = live(conn, ~p"/painel")
    pending_row = "#gaps-pending #recommendation-#{pending.id}"
    history_row = "#gaps-imported #recommendation-#{imported.id}"

    assert has_element?(
             view,
             "#{pending_row} > [data-recommendation-actions] > a:first-child[href='/importados?recomendacao=#{pending.id}']",
             "Conferir versões"
           )

    refute has_element?(view, "#{pending_row} details")
    assert has_element?(view, "#{history_row}", "Importada")

    assert has_element?(
             view,
             "#{history_row} details:not([open]) > summary",
             "Opções da sugestão"
           )

    assert has_element?(
             view,
             "#{history_row} details a[href='/importados?recomendacao=#{imported.id}']",
             "Conferir versões"
           )

    assert has_element?(view, "#{history_row} details a[target=_blank]", "Buscar no YouTube")
    view |> element("#{history_row} details button[phx-click=dismiss_rec]") |> render_click()
    assert Repertoire.get_recommendation(imported.id).status == :dismissed
    refute has_element?(view, history_row)
    assert has_element?(view, pending_row)
  end

  test "Dispensar hides a gap and marks it dismissed", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    rec =
      insert(:recommendation,
        artist: "Cartola",
        song: "O Mundo é um Moinho",
        genre_folder: "mpb",
        source: :gaps,
        status: :new
      )

    {:ok, view, _html} = live(conn, ~p"/painel")
    assert render(view) =~ "Cartola"

    view |> element("button[phx-click=dismiss_rec][phx-value-id='#{rec.id}']") |> render_click()

    html = render(view)
    refute html =~ "Cartola"
    assert Repertoire.get_recommendation(rec.id).status == :dismissed
  end
end
