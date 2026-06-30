defmodule BeatgridWeb.DashboardLiveTest do
  # async: false — the gaps flow enqueues a worker that talks to the (globally
  # stubbed) AI mock and the shared sandbox.
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Operations
  alias Beatgrid.Repertoire

  alias Beatgrid.Workers.{
    EnrichWorker,
    ExpandWorker,
    GainApplyWorker,
    LoudnessWorker,
    MarkerAnalyzeWorker,
    RecommendWorker
  }

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

  test "Mapear marcadores enqueues a worker per unmapped present track", %{conn: conn} do
    insert(:track, status: :present, rel_path: "u1.mp3", cue_points: [])
    insert(:track, status: :present, rel_path: "u2.mp3", cue_points: [])

    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Mapear marcadores (2)"

    html = view |> element("button", "Mapear marcadores") |> render_click()

    assert html =~ "Mapeando marcadores de 2 faixa"
    assert_enqueued(worker: MarkerAnalyzeWorker)
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

  test "Baixar enqueues a YouTube download and marks the gap imported", %{conn: conn} do
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
    view |> element("button[phx-click=download_rec][phx-value-id='#{rec.id}']") |> render_click()

    assert_enqueued(worker: ExpandWorker)
    assert Repertoire.get_recommendation(rec.id).status == :imported
    assert render(view) =~ "baixada"
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

  test "the Operações panel enqueues a library analysis", %{conn: conn} do
    insert(:track, status: :present)

    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Operações"
    assert html =~ "Análise de áudio local"
    assert html =~ "0/1 analisadas"

    html = view |> element("button[phx-click=analyze_library]") |> render_click()
    assert html =~ "enfileirada"
  end

  test "the Operações panel enqueues a loudness analysis", %{conn: conn} do
    insert(:track, status: :present, loudness_lufs: nil)

    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Loudness (LUFS)"

    view |> element("button[phx-click=analyze_loudness]") |> render_click()
    assert_enqueued(worker: LoudnessWorker)
  end

  test "the Operações panel enqueues pending gain application", %{conn: conn} do
    eligible =
      insert(:track,
        status: :present,
        loudness_lufs: -20.0,
        true_peak_dbtp: -8.0,
        loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
      )

    _inside_tolerance =
      insert(:track,
        status: :present,
        loudness_lufs: -14.5,
        true_peak_dbtp: -6.0,
        loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Apply gain (1)"

    html = view |> element("button[phx-click=apply_gain]") |> render_click()

    assert html =~ "1 track(s) queued"
    assert_enqueued(worker: GainApplyWorker, args: %{track_id: eligible.id})
  end

  @tag :tmp_dir
  test "the Operações panel restores the latest gain backup", %{conn: conn, tmp_dir: root} do
    previous = Application.get_env(:beatgrid, :library_root)
    Application.put_env(:beatgrid, :library_root, root)
    on_exit(fn -> Application.put_env(:beatgrid, :library_root, previous) end)

    rel_path = "_Inbox/restorable.mp3"
    backup_rel = "_Backups/Gain/batch/_Inbox/restorable.mp3"
    write_file(root, rel_path, "gain-applied-audio")
    write_file(root, backup_rel, "original-audio")

    track =
      insert(:track,
        status: :present,
        rel_path: rel_path,
        loudness_lufs: -14.0,
        true_peak_dbtp: -2.0,
        gain_applied_db: 6.0,
        gain_applied_at: ~U[2026-01-01 00:00:00Z]
      )

    batch_id = Ecto.UUID.generate()

    {:ok, _op} =
      Operations.record(%{
        track_id: track.id,
        kind: :gain,
        from: "6.0",
        to: backup_rel,
        batch_id: batch_id
      })

    expect(Beatgrid.Audio.LoudnessMock, :measure, fn path ->
      assert File.read!(path) == "original-audio"
      {:ok, %{lufs: -20.0, true_peak: -8.0, lra: 4.0}}
    end)

    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Restore gain backup"

    html = view |> element("button[phx-click=restore_gain_backup]") |> render_click()

    assert html =~ "1 gain backup(s) restored"
    assert File.read!(Path.join(root, rel_path)) == "original-audio"
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

  test "done: 0 with budget exhausted reads as 'cota esgotada', NOT 'nada pendente'",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/painel")

    # Halted on the very first track because there was no quota — there ARE pending
    # tracks (total: 174), so it must not claim "nada pendente".
    send(
      view.pid,
      {:enrich_progress,
       %{
         scope: "pending",
         status: :done,
         done: 0,
         total: 174,
         resolved: 0,
         budget_exhausted: true
       }}
    )

    html = render(view)
    assert html =~ "Cota do Soundcharts esgotada"
    refute html =~ "Nada pendente"
  end

  test "a youtube tick refreshes the pending-enrichment count live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/painel")
    assert render(view) =~ "Pendentes de enriquecimento: 0"

    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)
    send(view.pid, {:youtube_tick})

    assert render(view) =~ "Pendentes de enriquecimento: 1"
  end

  test "botão das raras enfileira EnrichWorker scope rare", %{conn: conn} do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    insert(:track,
      status: :present,
      soundcharts_song_id: nil,
      genre_folder: nil,
      sc_attempted_at: now
    )

    {:ok, view, html} = live(conn, ~p"/painel")
    assert html =~ "Soundcharts não achou"

    view |> element("button[phx-click=enrich_rare]") |> render_click()
    assert_enqueued(worker: Beatgrid.Workers.EnrichWorker, args: %{scope: "rare"})
  end

  test "an analysis tick refreshes the progress counts live", %{conn: conn} do
    track = insert(:track, status: :present)

    {:ok, view, _html} = live(conn, ~p"/painel")
    assert render(view) =~ "0/1 analisadas"

    {:ok, _} = Tracks.update(track, %{analyzed_at: ~U[2026-01-01 00:00:00Z]})
    send(view.pid, {:analysis_tick})

    assert render(view) =~ "1/1 analisadas"
  end

  defp write_file(root, rel_path, contents) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
