defmodule BeatgridWeb.MaintenanceLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Operations

  alias Beatgrid.Workers.{
    DbBackupWorker,
    EnrichWorker,
    GainApplyWorker,
    LoudnessWorker,
    MarkerAnalyzeWorker
  }

  setup :set_mox_global
  setup :isolate_library_root

  test "the repertoire links to a separate maintenance workspace", %{conn: conn} do
    {:ok, repertoire, _html} = live(conn, ~p"/painel")

    assert has_element?(repertoire, "#dashboard-gaps")
    refute has_element?(repertoire, "button[phx-click=analyze_library]")

    assert {:error, {:live_redirect, %{to: "/manutencao"}}} =
             repertoire
             |> element("#repertoire-maintenance", "Manutenção da biblioteca")
             |> render_click()

    {:ok, maintenance, _html} = live(conn, ~p"/manutencao")
    assert has_element?(maintenance, "h1", "Manutenção")
    assert has_element?(maintenance, "button[phx-click=analyze_library]")
    refute has_element?(maintenance, "#dashboard-gaps")
    assert has_element?(maintenance, "header a[href='/jobs']", "Ver fila de tarefas")

    assert {:error, {:live_redirect, %{to: "/ajustes"}}} =
             maintenance
             |> element("#maintenance-ajustes")
             |> render_click()
  end

  test "Mapear marcadores enqueues a worker per unmapped present track", %{conn: conn} do
    insert(:track, status: :present, rel_path: "u1.mp3", cue_points: [])
    insert(:track, status: :present, rel_path: "u2.mp3", cue_points: [])

    {:ok, view, html} = live(conn, ~p"/manutencao")
    assert html =~ "Mapear faltantes (2)"
    assert html =~ "0/2 com marcadores"
    assert has_element?(view, "button[phx-click=remap_markers][data-confirm]")

    html = view |> element("button", "Mapear faltantes") |> render_click()

    assert html =~ "Mapeando marcadores de 2 faixa"
    # both queued → the remap button flips to its busy state
    assert html =~ "Mapeamento em andamento…"
    assert_enqueued(worker: MarkerAnalyzeWorker)
  end

  test "the maintenance workspace enqueues a library analysis", %{conn: conn} do
    insert(:track, status: :present)

    {:ok, view, html} = live(conn, ~p"/manutencao")
    assert html =~ "Preparação de áudio"
    assert html =~ "Análise de áudio local"
    assert html =~ "0/1 analisadas"

    html = view |> element("button[phx-click=analyze_library]") |> render_click()
    assert html =~ "enfileirada"
  end

  test "the maintenance workspace enqueues a loudness analysis", %{conn: conn} do
    insert(:track, status: :present, loudness_lufs: nil)

    {:ok, view, html} = live(conn, ~p"/manutencao")
    assert html =~ "Loudness (LUFS)"

    view |> element("button[phx-click=analyze_loudness]") |> render_click()
    assert_enqueued(worker: LoudnessWorker)
  end

  test "the maintenance workspace enqueues pending gain application", %{conn: conn} do
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

    {:ok, view, html} = live(conn, ~p"/manutencao")
    assert html =~ "Aplicar ganho (1)"

    html = view |> element("button[phx-click=apply_gain]") |> render_click()

    assert html =~ "1 faixa(s) na fila para ajuste de ganho"
    assert_enqueued(worker: GainApplyWorker, args: %{track_id: eligible.id})
  end

  @tag :tmp_dir
  test "the maintenance workspace restores the latest gain backup", %{conn: conn, tmp_dir: root} do
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

    {:ok, view, html} = live(conn, ~p"/manutencao")
    assert html =~ "Desfazer último ajuste de ganho"

    html = view |> element("button[phx-click=restore_gain_backup]") |> render_click()

    assert html =~ "Áudio original restaurado em 1 faixa(s)"
    assert File.read!(Path.join(root, rel_path)) == "original-audio"
  end

  test "the YouTube panel opens the shared import review", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manutencao")
    assert has_element?(view, "#maintenance-enrichment a[href='/importados']", "Conferir links")
  end

  test "enriching pending YouTube imports enqueues an EnrichWorker batch job", %{conn: conn} do
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)

    {:ok, view, _html} = live(conn, ~p"/manutencao")
    view |> element("button[phx-click=enrich_youtube]") |> render_click()

    assert_enqueued(worker: EnrichWorker, args: %{scope: "pending"})
    # The progress bar shows while the batch is queued/running.
    assert render(view) =~ "Enriquecendo"
  end

  test "an enrich-progress :done event updates the note and pending count live",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manutencao")
    assert has_element?(view, "#maintenance-youtube p", "Pendentes de enriquecimento: 0")

    # A still-pending track exists when the batch finishes (its count is re-read).
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)

    send(
      view.pid,
      {:enrich_progress,
       %{scope: "pending", status: :done, done: 3, total: 3, resolved: 2, budget_exhausted: false}}
    )

    html = render(view)
    assert html =~ "3 enriquecida(s) (2 com match)"
    assert has_element?(view, "#maintenance-youtube p", "Pendentes de enriquecimento: 1")
  end

  test "an enrich-progress :done event with budget exhausted notes the exhausted quota",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manutencao")

    send(
      view.pid,
      {:enrich_progress,
       %{scope: "pending", status: :done, done: 1, total: 5, resolved: 0, budget_exhausted: true}}
    )

    assert render(view) =~ "cota esgotada"
  end

  test "done: 0 with budget exhausted reads as 'cota esgotada', NOT 'nada pendente'",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manutencao")

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
    {:ok, view, _html} = live(conn, ~p"/manutencao")
    assert has_element?(view, "#maintenance-youtube p", "Pendentes de enriquecimento: 0")

    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)
    send(view.pid, {:youtube_tick})

    assert has_element?(view, "#maintenance-youtube p", "Pendentes de enriquecimento: 1")
  end

  test "botão das raras enfileira EnrichWorker scope rare", %{conn: conn} do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    insert(:track,
      status: :present,
      soundcharts_song_id: nil,
      genre_folder: nil,
      sc_attempted_at: now
    )

    {:ok, view, html} = live(conn, ~p"/manutencao")
    assert html =~ "Soundcharts não achou"

    view |> element("button[phx-click=enrich_rare]") |> render_click()
    assert_enqueued(worker: Beatgrid.Workers.EnrichWorker, args: %{scope: "rare"})
  end

  test "an analysis tick refreshes the progress counts live", %{conn: conn} do
    track = insert(:track, status: :present)

    {:ok, view, _html} = live(conn, ~p"/manutencao")
    assert render(view) =~ "0/1 analisadas"

    {:ok, _} = Tracks.update(track, %{analyzed_at: ~U[2026-01-01 00:00:00Z]})
    send(view.pid, {:analysis_tick})

    assert render(view) =~ "1/1 analisadas"
  end

  @tag :tmp_dir
  test "the backup action queues a dump and exposes the restore command", %{
    conn: conn,
    tmp_dir: root
  } do
    {:ok, view, _html} = live(conn, ~p"/manutencao")
    assert has_element?(view, "#maintenance-database p", "Nenhum backup criado")

    view |> element("button[phx-click=db_backup]") |> render_click()
    assert_enqueued(worker: DbBackupWorker)

    write_file(root, "_Backups/DB/beatgrid-fixture.dump", "backup")
    send(view.pid, {:backup_tick})

    assert has_element?(view, "#maintenance-database details summary", "Comando para restaurar")
    assert has_element?(view, "#maintenance-database details code", "pg_restore -W")
    assert has_element?(view, "#maintenance-database details code", "beatgrid-fixture.dump")
    refute has_element?(view, "#maintenance-database details code", "PGPASSWORD=")
  end

  defp write_file(root, rel_path, contents) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
