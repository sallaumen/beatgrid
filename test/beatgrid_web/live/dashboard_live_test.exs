defmodule BeatgridWeb.DashboardLiveTest do
  # async: false — the gaps flow runs an async task that talks to the (globally
  # stubbed) AI mock and the shared sandbox.
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Workers.EnrichWorker

  setup :set_mox_global

  test "shows headline KPIs and the genre / artist distributions", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    song = insert(:soundcharts_song, tempo_bpm: 120.0, release_date: ~D[1975-03-01])

    insert(:track,
      status: :present,
      genre_folder: "mpb",
      tag_artist: "Jobim",
      soundcharts_song_id: song.id,
      sc_match_confidence: :high
    )

    insert(:track, status: :present, genre_folder: "mpb", tag_artist: "Gil")

    {:ok, _view, html} = live(conn, ~p"/painel")

    assert html =~ "Painel"
    assert html =~ "Total"
    assert html =~ "Resolvidas"
    assert html =~ "MPB"
    assert html =~ "Jobim"
    assert html =~ "1970s"
  end

  test "fetching repertoire gaps renders the AI suggestions", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    stub(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "gaps" => [
           %{"artist" => "Elis Regina", "song" => "Águas de Março", "reason" => "essencial MPB"}
         ]
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/painel")

    view |> element("button[phx-click=fetch_gaps]") |> render_click()
    html = render_async(view)

    assert html =~ "Elis Regina"
    assert html =~ "Águas de Março"
    assert html =~ "essencial MPB"
  end

  test "the Operações panel enqueues a library analysis", %{conn: conn} do
    insert(:track, status: :present)

    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Operações"
    assert html =~ "Análise de áudio local"
    assert html =~ "0/1 analisadas"

    html = view |> element("button[phx-click=analyze_library]") |> render_click()
    assert html =~ "enfileirada"
  end

  test "the YouTube panel enqueues downloads from pasted URLs", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Importar do YouTube"

    html =
      view
      |> form("#youtube-form")
      |> render_submit(%{urls: "https://y/1\nhttps://y/2"})

    assert html =~ "na fila"
    assert html =~ ~s(href="/jobs")
  end

  test "enriching pending YouTube imports enqueues an EnrichWorker batch job", %{conn: conn} do
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)

    {:ok, view, _html} = live(conn, ~p"/painel")
    view |> element("button[phx-click=enrich_youtube]") |> render_click()

    assert_enqueued(worker: EnrichWorker, args: %{scope: "pending"})
    # The progress bar shows while the batch is queued/running.
    assert render(view) =~ "Enriquecendo"
  end

  test "an enrich-progress :done event updates the note and pending count live",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/painel")
    assert render(view) =~ "Pendentes de enriquecimento: 0"

    # A still-pending track exists when the batch finishes (its count is re-read).
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)

    send(
      view.pid,
      {:enrich_progress,
       %{scope: "pending", status: :done, done: 3, total: 3, resolved: 2, budget_exhausted: false}}
    )

    html = render(view)
    assert html =~ "3 enriquecida(s) (2 com match)"
    assert html =~ "Pendentes de enriquecimento: 1"
  end

  test "an enrich-progress :done event with budget exhausted notes the exhausted quota",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/painel")

    send(
      view.pid,
      {:enrich_progress,
       %{scope: "pending", status: :done, done: 1, total: 5, resolved: 0, budget_exhausted: true}}
    )

    assert render(view) =~ "cota esgotada"
  end

  test "a youtube tick refreshes the pending-enrichment count live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/painel")
    assert render(view) =~ "Pendentes de enriquecimento: 0"

    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)
    send(view.pid, {:youtube_tick})

    assert render(view) =~ "Pendentes de enriquecimento: 1"
  end

  test "an analysis tick refreshes the progress counts live", %{conn: conn} do
    track = insert(:track, status: :present)

    {:ok, view, _html} = live(conn, ~p"/painel")
    assert render(view) =~ "0/1 analisadas"

    {:ok, _} = Tracks.update(track, %{analyzed_at: ~U[2026-01-01 00:00:00Z]})
    send(view.pid, {:analysis_tick})

    assert render(view) =~ "1/1 analisadas"
  end
end
