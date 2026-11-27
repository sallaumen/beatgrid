defmodule BeatgridWeb.DedupLiveTest do
  # async: false — the resolve flow touches disk and overrides :library_root, and
  # the scan enqueues an Oban job we assert on.
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Dedup
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Workers.DedupWorker

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      File.mkdir_p!(Path.join(root, "_Quarantine"))
    end

    :ok
  end

  # An exact-hash duplicate pair (a + b), both present on disk under MPB/.
  defp exact_pair(root) do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    File.mkdir_p!(Path.join(root, "MPB"))
    File.write!(Path.join(root, "MPB/a.mp3"), "x")
    File.write!(Path.join(root, "MPB/b.mp3"), "x")

    keep =
      insert(:track,
        status: :present,
        content_sha256: "h",
        bitrate_kbps: 320,
        genre_folder: "mpb",
        tag_artist: "Djavan",
        tag_title: "Sina",
        rel_path: "MPB/a.mp3",
        filename: "a.mp3"
      )

    dup =
      insert(:track,
        status: :present,
        content_sha256: "h",
        bitrate_kbps: 128,
        genre_folder: "mpb",
        tag_artist: "Djavan",
        tag_title: "Sina",
        rel_path: "MPB/b.mp3",
        filename: "b.mp3"
      )

    {:ok, _} = Dedup.detect()
    [g] = Dedup.list_pending()
    %{group: g, keep: keep, dup: dup}
  end

  test "renders the nav item and an empty state when nothing is pending", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dedup")

    assert html =~ "Duplicatas"
    assert html =~ "Nenhuma duplicata pendente"
    # a note that different-artist versions are never grouped
    assert html =~ "artista"
  end

  test "the empty queue offers one scan control and links to quarantine recovery", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dedup")
    assert length(:binary.matches(html, ~s(phx-click="scan"))) == 1
    assert has_element?(view, "a[href='/resgate#quarentena']", "Recuperar cópias da quarentena")
  end

  @tag :tmp_dir
  test "renders a pending group card with its members and match tag", %{conn: conn, tmp_dir: root} do
    %{group: group, keep: keep, dup: dup} = exact_pair(root)

    {:ok, view, html} = live(conn, ~p"/dedup")

    assert html =~ "Duplicatas"
    assert html =~ "· 1 grupo"
    # the exact-hash match reads as "exata"
    assert html =~ "exata"
    # both members shown (artist — title)
    assert html =~ "Djavan"
    assert html =~ "Sina"
    assert has_element?(view, "a[href='/track/#{keep.id}']", "Sina")
    assert has_element?(view, "a[href='/track/#{dup.id}']", "Sina")
    # A DJ must be able to identify the specific recording and its file, even when
    # the artist/title match exactly.
    assert has_element?(view, "#copy-#{keep.id}", "MPB/a.mp3")
    assert has_element?(view, "#copy-#{dup.id}", "MPB/b.mp3")
    assert has_element?(view, "#copy-#{keep.id} dd", "320 kbps")
    assert has_element?(view, "#copy-#{dup.id} dd", "128 kbps")

    assert has_element?(
             view,
             "#copy-#{keep.id} input[type=radio][name='keeper-#{group.id}'][checked]"
           )

    assert has_element?(view, "#copy-#{dup.id} input[type=radio][name='keeper-#{group.id}']")
    refute has_element?(view, "#copy-#{dup.id} input[checked]")
    assert has_element?(view, "footer p", "1 cópia será mantida")

    assert has_element?(
             view,
             "button[phx-click=resolve]",
             "Manter selecionada e mover 1 cópia para a quarentena"
           )

    assert has_element?(view, "#copy-#{keep.id}", "Cópia selecionada")
    assert has_element?(view, "#copy-#{dup.id}", "Vai para a quarentena")
  end

  test "identical filenames are distinguishable and the confirmation names the selected path", %{
    conn: conn
  } do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    keep =
      insert(:track,
        content_sha256: "same",
        bitrate_kbps: 320,
        genre_folder: "mpb",
        tag_artist: "Djavan",
        tag_title: "Sina",
        rel_path: "MPB/Sina.mp3",
        filename: "Sina.mp3"
      )

    dup =
      insert(:track,
        content_sha256: "same",
        bitrate_kbps: 128,
        tag_artist: "Djavan",
        tag_title: "Sina",
        rel_path: "_Inbox/Sina.mp3",
        filename: "Sina.mp3"
      )

    {:ok, _} = Dedup.detect()
    [g] = Dedup.list_pending()
    {:ok, view, _html} = live(conn, ~p"/dedup")

    assert has_element?(
             view,
             "#copy-#{keep.id} input[type=radio][aria-label='Escolher cópia para manter: MPB/Sina.mp3']"
           )

    assert has_element?(
             view,
             "#copy-#{dup.id} input[type=radio][aria-label='Escolher cópia para manter: _Inbox/Sina.mp3']"
           )

    assert has_element?(view, "#copy-#{keep.id}", "Recomendada")

    assert has_element?(
             view,
             "button[phx-click=resolve][phx-value-track='#{keep.id}'][data-confirm*='MPB/Sina.mp3']"
           )

    view |> element("#copy-#{dup.id} input[type=radio]") |> render_click()
    assert has_element?(view, "#copy-#{keep.id}", "Recomendada")
    assert has_element?(view, "#copy-#{keep.id}", "Vai para a quarentena")

    assert has_element?(
             view,
             "button[phx-click=resolve][phx-value-track='#{dup.id}'][data-confirm*='_Inbox/Sina.mp3']"
           )

    html = render_click(view, "resolve", %{"group" => g.id, "track" => keep.id})
    assert html =~ "A seleção mudou"
    assert Dedup.get_group(g.id).status == :pending
    assert Tracks.get(keep.id).status == :present
    assert Tracks.get(dup.id).status == :present
    assert has_element?(view, "#copy-#{dup.id} input[checked]")
  end

  test "a changed recording invalidates the previous quarantine preview", %{conn: conn} do
    keep = insert(:track, norm_artist: "djavan", norm_title: "sina", bitrate_kbps: 320)
    dup = insert(:track, norm_artist: "djavan", norm_title: "sina", bitrate_kbps: 128)
    {:ok, _} = Dedup.detect()
    [g] = Dedup.list_pending()
    {:ok, view, _html} = live(conn, ~p"/dedup")
    assert has_element?(view, "#copy-#{dup.id}", "Vai para a quarentena")
    assert {:ok, _} = Tracks.update(dup, %{tag_isrc: "BRBBB0000002"})

    html = render_click(view, "resolve", %{"group" => g.id, "track" => keep.id})
    assert html =~ "A seleção mudou"
    assert Dedup.get_group(g.id).status == :pending
    assert has_element?(view, "#copy-#{dup.id}", "Manter · ISRC diferente")
  end

  test "closing a different group preserves the user's in-progress keeper choice", %{conn: conn} do
    keep = insert(:track, content_sha256: "first", bitrate_kbps: 320)
    dup = insert(:track, content_sha256: "first", bitrate_kbps: 128)
    insert(:track, content_sha256: "second")
    insert(:track, content_sha256: "second")
    {:ok, _} = Dedup.detect()
    groups = Dedup.list_pending()
    first = Enum.find(groups, &(&1.signature == "first"))
    second = Enum.find(groups, &(&1.signature == "second"))
    {:ok, view, _html} = live(conn, ~p"/dedup")

    view |> element("#copy-#{dup.id} input[type=radio]") |> render_click()
    view |> element("button[phx-click=ignore][phx-value-group='#{second.id}']") |> render_click()
    assert has_element?(view, "#copy-#{dup.id} input[checked]")
    refute has_element?(view, "#copy-#{keep.id} input[checked]")

    assert has_element?(
             view,
             "button[phx-click=resolve][phx-value-group='#{first.id}'][phx-value-track='#{dup.id}']"
           )
  end

  test "distinct ISRCs explain why both copies stay, without a redundant move action", %{
    conn: conn
  } do
    first = insert(:track, norm_artist: "djavan", norm_title: "sina", tag_isrc: "BRAAA0000001")
    second = insert(:track, norm_artist: "djavan", norm_title: "sina", tag_isrc: "BRBBB0000002")
    {:ok, _} = Dedup.detect()
    {:ok, view, _html} = live(conn, ~p"/dedup")
    assert has_element?(view, "#copy-#{first.id} dd", "BRAAA0000001")
    assert has_element?(view, "#copy-#{second.id} dd", "BRBBB0000002")
    assert has_element?(view, "footer p", "2 cópias serão mantidas")
    assert has_element?(view, "button[phx-click=resolve]", "Encerrar grupo sem mover arquivos")
    refute has_element?(view, "button[phx-click=ignore]")
    refute has_element?(view, "button[phx-click=resolve][data-confirm]")
  end

  @tag :tmp_dir
  test "cada membro tem play na capa (cover_play) pra ouvir e comparar as versões", %{
    conn: conn,
    tmp_dir: root
  } do
    %{keep: keep, dup: dup} = exact_pair(root)

    {:ok, _view, html} = live(conn, ~p"/dedup")

    assert html =~ "beatgrid:play"
    assert html =~ "/audio/#{keep.id}"
    assert html =~ "/audio/#{dup.id}"
  end

  test "Procurar duplicatas enqueues a DedupWorker and shows the scanning label", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dedup")

    html = view |> element("header button[phx-click=scan]") |> render_click()

    assert [_job] = all_enqueued(worker: DedupWorker)
    assert html =~ "Procurando"
  end

  @tag :tmp_dir
  test "Manter selecionada + quarentenar quarantines the non-keeper and toasts", %{
    conn: conn,
    tmp_dir: root
  } do
    %{group: g, dup: dup} = exact_pair(root)

    {:ok, view, _html} = live(conn, ~p"/dedup")

    html =
      view
      |> element("button[phx-click=resolve][phx-value-group='#{g.id}']")
      |> render_click()

    assert Tracks.get(dup.id).status == :quarantined
    assert File.exists?(Path.join(root, "_Quarantine/b.mp3"))
    assert Dedup.get_group(g.id).status == :resolved
    # the undo toast appears
    assert html =~ "Desfazer"
    # the group leaves the pending list, so the empty state shows
    assert html =~ "Nenhuma duplicata pendente"
  end

  @tag :tmp_dir
  test "switching the keeper radio keeps the chosen copy and quarantines the default", %{
    conn: conn,
    tmp_dir: root
  } do
    # The 320 kbps copy (keep) is the suggested keeper; switch to the 128 kbps one.
    %{group: g, keep: keep, dup: dup} = exact_pair(root)

    {:ok, view, _html} = live(conn, ~p"/dedup")

    view
    |> element(
      "input[phx-click=pick_keeper][phx-value-group='#{g.id}'][phx-value-track='#{dup.id}']"
    )
    |> render_click()

    assert has_element?(view, "#copy-#{dup.id} input[checked]")
    refute has_element?(view, "#copy-#{keep.id} input[checked]")
    assert has_element?(view, "#copy-#{dup.id}", "Cópia selecionada")
    assert has_element?(view, "#copy-#{keep.id}", "Vai para a quarentena")
    assert Tracks.get(keep.id).status == :present

    view
    |> element("button[phx-click=resolve][phx-value-group='#{g.id}']")
    |> render_click()

    # the chosen copy (dup) stays; the previously-suggested keeper is quarantined
    assert Tracks.get(dup.id).status == :present
    assert Tracks.get(keep.id).status == :quarantined
    assert Dedup.get_group(g.id).keeper_track_id == dup.id
  end

  @tag :tmp_dir
  test "Ignorar resolves the group without quarantining", %{conn: conn, tmp_dir: root} do
    %{group: g, keep: keep, dup: dup} = exact_pair(root)

    {:ok, view, _html} = live(conn, ~p"/dedup")

    view
    |> element("button[phx-click=ignore][phx-value-group='#{g.id}']")
    |> render_click()

    assert Dedup.get_group(g.id).status == :resolved
    assert Tracks.get(keep.id).status == :present
    assert Tracks.get(dup.id).status == :present
  end

  @tag :tmp_dir
  test "partial quarantine reports the actual moves and permits undo of its batch", %{
    conn: conn,
    tmp_dir: root
  } do
    %{keep: keep, dup: dup} = exact_pair(root)

    missing =
      insert(:track, content_sha256: "h", rel_path: "MPB/missing.mp3", filename: "missing.mp3")

    {:ok, _} = Dedup.detect()
    [g] = Dedup.list_pending()
    {:ok, view, _html} = live(conn, ~p"/dedup")

    html =
      view |> element("button[phx-click=resolve][phx-value-group='#{g.id}']") |> render_click()

    assert html =~ "1 cópia movida"
    assert html =~ "1 falha"
    assert html =~ "MPB/missing.mp3"
    assert Dedup.get_group(g.id).status == :pending
    assert has_element?(view, "#copy-#{dup.id} input[type=radio][disabled]")
    assert has_element?(view, "#copy-#{dup.id}", "Já na quarentena")
    assert has_element?(view, "#copy-#{keep.id} input[checked]")
    assert Tracks.get(dup.id).status == :quarantined
    assert Tracks.get(missing.id).status == :present

    view |> element("button[phx-click=undo]") |> render_click()
    assert Tracks.get(dup.id).status == :present
    assert has_element?(view, "#copy-#{dup.id} input[type=radio]")
    refute has_element?(view, "#copy-#{dup.id} input[type=radio][disabled]")
  end

  @tag :tmp_dir
  test "mixed restoration keeps the failed batch retryable until every copy is recovered", %{
    conn: conn,
    tmp_dir: root
  } do
    %{keep: keep, dup: dup} = exact_pair(root)
    File.write!(Path.join(root, "MPB/c.mp3"), "x")
    third = insert(:track, content_sha256: "h", rel_path: "MPB/c.mp3", filename: "c.mp3")
    {:ok, _} = Dedup.detect()
    [g] = Dedup.list_pending()
    {:ok, view, _html} = live(conn, ~p"/dedup")
    view |> element("button[phx-click=resolve][phx-value-group='#{g.id}']") |> render_click()
    assert Tracks.get(keep.id).status == :present
    assert Tracks.get(dup.id).status == :quarantined
    assert Tracks.get(third.id).status == :quarantined

    File.rename!(
      Path.join(root, "_Quarantine/c.mp3"),
      Path.join(root, "c-temporarily-missing.mp3")
    )

    html = view |> element("button[phx-click=undo]") |> render_click()
    assert html =~ "1 restaurada"
    assert html =~ "1 falha"
    assert has_element?(view, "button[phx-click=undo]", "Tentar desfazer novamente")
    assert Dedup.get_group(g.id).status == :resolved
    assert Tracks.get(dup.id).status == :present
    assert Tracks.get(third.id).status == :quarantined

    assert [%{status: :applied, error: error}] =
             Beatgrid.Operations.list_by(track_id: third.id, kind: :quarantine)

    assert error =~ "source_missing"

    File.rename!(
      Path.join(root, "c-temporarily-missing.mp3"),
      Path.join(root, "_Quarantine/c.mp3")
    )

    view |> element("button[phx-click=undo]") |> render_click()
    assert Tracks.get(third.id).status == :present
    assert Tracks.get(third.id).rel_path == "MPB/c.mp3"
    assert Dedup.get_group(g.id).status == :pending

    assert [%{status: :undone, error: nil}] =
             Beatgrid.Operations.list_by(track_id: third.id, kind: :quarantine)
  end

  @tag :tmp_dir
  test "Desfazer restores the quarantined track and re-opens the group", %{
    conn: conn,
    tmp_dir: root
  } do
    %{group: g, dup: dup} = exact_pair(root)

    {:ok, view, _html} = live(conn, ~p"/dedup")

    view
    |> element("button[phx-click=resolve][phx-value-group='#{g.id}']")
    |> render_click()

    assert Tracks.get(dup.id).status == :quarantined

    html = view |> element("button[phx-click=undo]") |> render_click()

    assert Tracks.get(dup.id).status == :present
    assert File.exists?(Path.join(root, "MPB/b.mp3"))
    assert Dedup.get_group(g.id).status == :pending
    # the group is pending again, so the card is back (and the toast is gone)
    assert html =~ "exata"
    refute html =~ "Desfazer"
  end

  @tag :tmp_dir
  test "a done dedup_progress event reloads the groups", %{conn: conn, tmp_dir: root} do
    {:ok, view, html} = live(conn, ~p"/dedup")
    assert html =~ "Nenhuma duplicata pendente"

    # create a pair, then simulate the worker finishing its scan
    exact_pair(root)
    send(view.pid, {:dedup_progress, %{status: :done, batch_id: "b1", groups: 1}})

    html = render(view)
    assert html =~ "· 1 grupo"
    assert html =~ "exata"
    refute html =~ "Procurando"
  end
end
