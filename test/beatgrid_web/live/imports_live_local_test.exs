defmodule BeatgridWeb.ImportsLiveLocalTest do
  # async: false — the preview runs an async task that reads the filesystem and the
  # shared sandbox, and these tests override the global :library_root app env.
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library
  alias Beatgrid.Workers.ImportWorker

  setup :set_mox_global

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
    end

    :ok
  end

  test "the Biblioteca shortcut opens the local import page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#import-source")

    assert {:ok, imports, html} =
             view
             |> element(~s(header a[href="/importados?origem=local"]), "Importar")
             |> render_click()
             |> follow_redirect(conn, ~p"/importados?origem=local")

    assert html =~ "Importar pasta ou arquivo"
    assert has_element?(imports, "#import-source")
    assert has_element?(imports, "#import-browser")
    refute has_element?(imports, "#link-preview")
  end

  test "the old Biblioteca import URL redirects to the local import page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/importados?origem=local"}}} =
             live(conn, ~p"/?importar=1")
  end

  test "the source links switch modes with URL patches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/importados")
    assert has_element?(view, "#link-preview")
    refute has_element?(view, "#import-source")

    view |> element("#import-sources a", "Pasta ou arquivo") |> render_click()
    assert_patch(view, ~p"/importados?origem=local")
    assert has_element?(view, "#import-source")
    refute has_element?(view, "#link-preview")

    view |> element("#import-sources a", "YouTube e Spotify") |> render_click()
    assert_patch(view, ~p"/importados")
    assert has_element?(view, "#link-preview")
    refute has_element?(view, "#import-source")
  end

  @tag :tmp_dir
  test "submitting a path previews proposed artist/title per file", %{conn: conn, tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Djavan - Sina.mp3"), "tagged-bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
      {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
    end)

    {:ok, view, _html} = live(conn, ~p"/importados?origem=local")

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
  test "a bogus path shows the not-found error", %{conn: conn, tmp_dir: root} do
    {:ok, view, _html} = live(conn, ~p"/importados?origem=local")

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

    {:ok, view, _html} = live(conn, ~p"/importados?origem=local")

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
        items: [
          %{
            source_path: new_file,
            sha256: "a81835154802d331b2e9e39908c14afbd2489b72aac0e7acc614c085bc603a86",
            artist: "Djavan",
            title: "Sina (editado)"
          }
        ],
        resolve_soundcharts: true
      }
    )

    assert render(view) =~ "Importando — na fila"
    refute has_element?(view, "#import-run")
    assert has_element?(view, "#import-source")
  end

  @tag :tmp_dir
  test "the preview flags a near-duplicate row with a 'parecida já existe' tag", %{
    conn: conn,
    tmp_dir: root
  } do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Djavan - Sina.mp3"), "other-bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
      {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
    end)

    # A present track with the SAME normalized artist+title but a DIFFERENT hash:
    # a fuzzy near-dup the import should warn about (still importable).
    insert(:track,
      status: :present,
      content_sha256: "a-different-hash",
      tag_artist: "Djavan",
      tag_title: "Sina",
      norm_artist: "djavan",
      norm_title: "sina",
      rel_path: "MPB/sina.mp3",
      filename: "sina.mp3"
    )

    {:ok, view, _html} = live(conn, ~p"/importados?origem=local")

    view
    |> form("#import-source", %{source: src})
    |> render_submit()

    html = render_async(view)
    assert html =~ "parecida já existe"
    # it is NOT the hard exact-skip tag — the row stays importable
    refute html =~ "duplicada — será pulada"
  end

  test "a running import-progress event shows a live progress bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/importados?origem=local")

    Library.broadcast_import(%{batch_id: "b1", status: :running, done: 1, total: 3, imported: 1})

    assert render(view) =~ "Importando 1/3"
  end

  test "a done import-progress event shows the result and clears the bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/importados?origem=local")

    Library.broadcast_import(%{batch_id: "b1", status: :running, done: 0, total: 1, imported: 0})

    assert render(view) =~ "Importando"

    Library.broadcast_import(%{
      batch_id: "b1",
      status: :done,
      done: 1,
      total: 1,
      imported: 1,
      skipped: 0
    })

    html = render(view)
    assert html =~ "1 faixa(s) importada(s)."
    refute html =~ "Importando"
  end

  test "Biblioteca refreshes after the import finishes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    insert(:track, status: :present, tag_title: "Nova faixa")

    Library.broadcast_import(%{
      batch_id: "b1",
      status: :done,
      done: 1,
      total: 1,
      imported: 1,
      skipped: 0
    })

    assert has_element?(view, "a", "Nova faixa")
    refute has_element?(view, "#local-import-activity")
  end

  describe "folder browser" do
    @tag :tmp_dir
    test "lists the start directory and lets you open a subfolder", %{conn: conn, tmp_dir: root} do
      shows = Path.join(root, "shows")
      File.mkdir_p!(shows)
      File.write!(Path.join(shows, "Josy - Todo Mundo Bole.mpeg"), "x")
      File.write!(Path.join(root, "capa.jpg"), "x")

      {:ok, view, _html} = live(conn, ~p"/importados?origem=local")
      assert has_element?(view, "#import-browser")

      # Navigate to the tmp root: the subdir shows, the jpg does not.
      html = render_click(with_target(view, "#local-import"), "browse_to", %{"dir" => root})
      assert html =~ "shows"
      refute html =~ "capa.jpg"

      # Descend into the subdir: the candidate file is listed.
      html = render_click(with_target(view, "#local-import"), "browse_to", %{"dir" => shows})
      assert html =~ "Josy - Todo Mundo Bole.mpeg"
    end

    @tag :tmp_dir
    test "picking a file previews it with the current import options", %{
      conn: conn,
      tmp_dir: root
    } do
      file = Path.join(root, "Savinho - Sorrindo e Cantando.mp4")
      File.write!(file, "aac-bytes")

      stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
        {:ok, %Metadata{format_name: "mov,mp4,m4a,3gp,3g2,mj2", duration_ms: 177_393}}
      end)

      stub(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok, %{"titles" => [%{"artist" => "Savinho", "title" => "Sorrindo e Cantando"}]}}
      end)

      {:ok, view, _html} = live(conn, ~p"/importados?origem=local")
      render_click(with_target(view, "#local-import"), "browse_to", %{"dir" => root})

      view |> form("#import-source", %{ai: "on", soundcharts: "on"}) |> render_change()
      render_click(with_target(view, "#local-import"), "browse_pick", %{"file" => file})
      html = render_async(view)
      assert html =~ "1 nova(s), 0 duplicada(s)"
      assert html =~ "Savinho"
      assert html =~ "+ Soundcharts"
    end

    @tag :tmp_dir
    test "the folder action previews the current directory", %{conn: conn, tmp_dir: root} do
      File.write!(Path.join(root, "a.mp3"), "a")
      File.write!(Path.join(root, "b.mp3"), "b")

      stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
        {:ok, %Metadata{title: "T", artist: "A", duration_ms: 100_000}}
      end)

      {:ok, view, _html} = live(conn, ~p"/importados?origem=local")
      render_click(with_target(view, "#local-import"), "browse_to", %{"dir" => root})

      render_click(with_target(view, "#local-import"), "browse_import_here", %{})
      html = render_async(view)
      assert html =~ "2 nova(s), 0 duplicada(s)"
    end

    @tag :tmp_dir
    test "an empty folder says so instead of showing a bare panel", %{conn: conn, tmp_dir: root} do
      vazio = Path.join(root, "vazio")
      File.mkdir_p!(vazio)

      {:ok, view, _html} = live(conn, ~p"/importados?origem=local")

      html = render_click(with_target(view, "#local-import"), "browse_to", %{"dir" => vazio})
      assert html =~ "Nada importável aqui"
    end
  end
end
