defmodule BeatgridWeb.DashboardLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
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
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    {:ok, view, _html} = live(conn, ~p"/painel")
    view |> element("button[phx-click=fetch_gaps]") |> render_click()

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
