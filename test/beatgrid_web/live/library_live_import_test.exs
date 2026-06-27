defmodule BeatgridWeb.LibraryLiveImportTest do
  # async: false — the preview runs an async task that reads the filesystem and the
  # shared sandbox, and these tests override the global :library_root app env.
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Workers.ImportWorker

  setup :set_mox_global

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  test "clicking Importar opens the import modal", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "Importar pasta ou arquivo"

    html = view |> element("button[phx-click=show_import]") |> render_click()
    assert html =~ "Importar pasta ou arquivo"
    assert html =~ "Cole o caminho de uma pasta ou arquivo"
  end

  test "the backdrop / ✕ closes the modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-click=show_import]") |> render_click()

    html = view |> element("div[phx-click=hide_import]") |> render_click()
    refute html =~ "Importar pasta ou arquivo"
  end

  @tag :tmp_dir
  test "submitting a path previews proposed artist/title per file", %{conn: conn, tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Djavan - Sina.mp3"), "tagged-bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
      {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-click=show_import]") |> render_click()

    view
    |> form("#import-source", %{source: src})
    |> render_submit()

    html = render_async(view)
    assert html =~ "1 nova(s), 0 duplicada(s)"
    assert html =~ "Djavan"
    assert html =~ "Sina"
    assert html =~ "Importar 1 faixa(s)"
  end

  @tag :tmp_dir
  test "a bogus path shows the not-found error in the modal", %{conn: conn, tmp_dir: root} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-click=show_import]") |> render_click()

    view
    |> form("#import-source", %{source: Path.join(root, "nope")})
    |> render_submit()

    html = render_async(view)
    assert html =~ "Caminho não encontrado"
  end

  @tag :tmp_dir
  test "running the import enqueues ImportWorker with the edited overrides", %{
    conn: conn,
    tmp_dir: root
  } do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    new_file = Path.join(src, "Djavan - Sina.mp3")
    File.write!(new_file, "new-bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
      {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-click=show_import]") |> render_click()

    # Preview (with the opt-in Soundcharts box ticked) so we have rows to import.
    view
    |> form("#import-source", %{source: src, soundcharts: "on"})
    |> render_submit()

    render_async(view)

    # Edit the proposed title before committing.
    view
    |> form("#import-run", %{
      items: %{"0" => %{source_path: new_file, artist: "Djavan", title: "Sina (editado)"}}
    })
    |> render_submit()

    assert_enqueued(
      worker: ImportWorker,
      args: %{
        items: [%{source_path: new_file, artist: "Djavan", title: "Sina (editado)"}],
        resolve_soundcharts: true
      }
    )

    # The modal closes and a queued progress bar appears in the header.
    html = render(view)
    refute html =~ "Importar pasta ou arquivo"
    assert html =~ "Importando — na fila"
  end

  test "a running import-progress event shows a live progress bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    send(
      view.pid,
      {:import_progress, %{batch_id: "b1", status: :running, done: 1, total: 3, imported: 1}}
    )

    assert render(view) =~ "Importando 1/3"
  end

  test "a done import-progress event reloads the table, toasts, and clears the bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Open + put the view into a queued state so we can prove the bar clears.
    send(
      view.pid,
      {:import_progress, %{batch_id: "b1", status: :running, done: 0, total: 1, imported: 0}}
    )

    assert render(view) =~ "Importando"

    # A track now exists; the :done handler re-reads the library table.
    insert(:track, status: :present, tag_title: "Sina", tag_artist: "Djavan")

    send(
      view.pid,
      {:import_progress,
       %{batch_id: "b1", status: :done, done: 1, total: 1, imported: 1, skipped: 0}}
    )

    html = render(view)
    assert html =~ "1 faixa(s) importada(s)."
    assert html =~ "Sina"
    refute html =~ "Importando"
  end
end
