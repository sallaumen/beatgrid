defmodule BeatgridWeb.RescueLiveTest do
  # async: false — isolate_library_root swaps a GLOBAL app env (see RescueTest).
  use BeatgridWeb.ConnCase, async: false

  import Beatgrid.Factory
  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Operations

  setup :isolate_library_root

  test "renders the census and the empty states", %{conn: conn} do
    insert(:track, status: :present, rel_path: "ok.mp3", integrity_status: :ok)

    {:ok, view, html} = live(conn, ~p"/resgate")

    assert has_element?(
             view,
             "nav[aria-label='Categorias de recuperação'] a[href='#arquivos-danificados']",
             "Arquivos com problema"
           )

    assert has_element?(
             view,
             "nav[aria-label='Categorias de recuperação'] a[href='#quarentena']",
             "Quarentena"
           )

    assert html =~ "Recuperação de arquivos"
    assert html =~ "Íntegras"
    assert html =~ "Nenhum arquivo ausente ou corrompido identificado"
    assert html =~ "Quarentena vazia"
  end

  test "damaged and quarantined rows offer their restores", %{conn: conn} do
    ghost =
      insert(:track,
        status: :present,
        tag_title: "Hora do Adeus",
        rel_path: "Forró/adeus.mp3",
        integrity_status: :missing_file
      )

    backup_rel = Path.join(["_Backups", "Gain", ghost.id, Uniq.UUID.uuid7(), ghost.rel_path])
    backup_path = Path.join(Library.library_root(), backup_rel)
    File.mkdir_p!(Path.dirname(backup_path))
    File.write!(backup_path, "audio")

    {:ok, _op} =
      Operations.record(%{
        track_id: ghost.id,
        kind: :gain,
        status: :applied,
        from: "3.5",
        to: backup_rel,
        batch_id: Uniq.UUID.uuid7()
      })

    quarantined =
      insert(:track,
        status: :quarantined,
        tag_title: "Dupla Esquecida",
        rel_path: "_Quarantine/dupla.mp3"
      )

    {:ok, _op} =
      Operations.record(%{
        track_id: quarantined.id,
        kind: :quarantine,
        status: :applied,
        from: "Forró/dupla.mp3",
        to: quarantined.rel_path,
        batch_id: Uniq.UUID.uuid7()
      })

    {:ok, view, html} = live(conn, ~p"/resgate")

    assert has_element?(
             view,
             "#arquivo-#{ghost.id} a[href='/track/#{ghost.id}']",
             "Hora do Adeus"
           )

    assert has_element?(view, "#quarentena a[href='/dedup']", "Revisar duplicatas")
    assert html =~ "Arquivo ausente"
    assert has_element?(view, "#arquivo-#{ghost.id} dd", "Forró/adeus.mp3")

    assert has_element?(
             view,
             "#arquivo-#{ghost.id} button[phx-click=restore][data-confirm]",
             "Restaurar do backup"
           )

    refute has_element?(view, "#arquivo-#{quarantined.id} button[phx-click=unquarantine]")
    assert html =~ "Restaurar todas com backup (1)"
    assert html =~ "Dupla Esquecida"
    assert html =~ "Forró/dupla.mp3"

    # this quarantined row has NO file on disk — a ghost gets the truth, not a
    # Restaurar button that would fail
    assert html =~ "Arquivo ausente na quarentena"
  end

  test "a quarantined row WITH its file keeps the Restaurar button", %{conn: conn} do
    track = insert(:track, status: :quarantined, rel_path: "_Quarantine/viva.mp3")
    path = Path.join(Library.library_root(), track.rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "x")

    {:ok, _op} =
      Operations.record(%{
        track_id: track.id,
        kind: :quarantine,
        status: :applied,
        from: "Forró/viva.mp3",
        to: track.rel_path,
        batch_id: Uniq.UUID.uuid7()
      })

    {:ok, view, html} = live(conn, ~p"/resgate")

    assert has_element?(view, "#arquivo-#{track.id} dd", "Forró/viva.mp3")
    assert has_element?(view, "#arquivo-#{track.id} button[phx-click=unquarantine]", "Restaurar")
    refute html =~ "Arquivo ausente na quarentena"
  end

  test "identifies the correct quarantine copy by artist, source and destination", %{conn: conn} do
    first =
      quarantine_copy("Águas de Março", "Elis Regina", "_Quarantine/versao-1.mp3", "MPB/elis.mp3")

    second =
      quarantine_copy("Águas de Março", "Tom Jobim", "_Quarantine/versao-2.mp3", "MPB/tom.mp3")

    {:ok, view, _html} = live(conn, ~p"/resgate")

    assert has_element?(
             view,
             "#arquivo-#{first.id} a[href='/track/#{first.id}']",
             "Águas de Março"
           )

    assert has_element?(view, "#arquivo-#{first.id}", "Elis Regina")
    assert has_element?(view, "#arquivo-#{first.id} dd", "_Quarantine/versao-1.mp3")
    assert has_element?(view, "#arquivo-#{second.id} dd", "MPB/tom.mp3")

    search_quarantine(view, "aguas de marco", "all")
    assert has_element?(view, "#arquivo-#{first.id}")
    assert has_element?(view, "#arquivo-#{second.id}")

    search_quarantine(view, "tom jobim", "all")
    refute has_element?(view, "#arquivo-#{first.id}")
    assert has_element?(view, "#arquivo-#{second.id}")

    search_quarantine(view, "versao-2.mp3", "all")
    assert has_element?(view, "#arquivo-#{second.id}")

    assert has_element?(
             view,
             "#arquivo-#{second.id} button[data-confirm*='_Quarantine/versao-2.mp3'][data-confirm*='MPB/tom.mp3']"
           )

    view |> element("#arquivo-#{second.id} button[phx-click=unquarantine]") |> render_click()
    refute has_element?(view, "#arquivo-#{second.id}")
    assert has_element?(view, "#quarentena", "Nenhuma faixa corresponde à busca")

    assert File.exists?(Path.join(Library.library_root(), "MPB/tom.mp3"))
    assert File.exists?(Path.join(Library.library_root(), first.rel_path))
    refute File.exists?(Path.join(Library.library_root(), second.rel_path))

    search_quarantine(view, "elis.mp3", "all")
    assert has_element?(view, "#arquivo-#{first.id}")
  end

  test "quarantine restoration reports the actual path when the origin is occupied", %{conn: conn} do
    track = quarantine_copy("Forró", "Artista", "_Quarantine/versao.mp3", "Forró/versao.mp3")
    original = Path.join(Library.library_root(), "Forró/versao.mp3")
    File.write!(original, "already there")

    {:ok, view, _html} = live(conn, ~p"/resgate")
    view |> element("#arquivo-#{track.id} button[phx-click=unquarantine]") |> render_click()

    restored = Tracks.get(track.id)
    assert restored.rel_path != "Forró/versao.mp3"
    assert restored.status == :present
    assert has_element?(view, "#flash-info", restored.rel_path)
    assert File.read!(original) == "already there"
    assert File.read!(Path.join(Library.library_root(), restored.rel_path)) == "audio"
  end

  test "filters quarantine copies by the reason recovery is or is not available", %{conn: conn} do
    available = quarantine_copy("Viva", "Artista", "_Quarantine/viva.mp3", "Forró/viva.mp3")

    missing =
      quarantine_copy("Ausente", "Artista", "_Quarantine/ausente.mp3", "Forró/ausente.mp3")

    File.rm!(Path.join(Library.library_root(), missing.rel_path))
    unknown = quarantine_copy("Sem origem", "Artista", "_Quarantine/orfa.mp3", nil)

    {:ok, view, _html} = live(conn, ~p"/resgate")

    assert has_element?(view, "#quarantine-availability.h-9")
    search_quarantine(view, "", "ready")
    assert has_element?(view, "#arquivo-#{available.id} button[phx-click=unquarantine]")
    refute has_element?(view, "#arquivo-#{missing.id}")
    refute has_element?(view, "#arquivo-#{unknown.id}")

    search_quarantine(view, "", "missing")
    assert has_element?(view, "#arquivo-#{missing.id}", "Arquivo ausente na quarentena")
    refute has_element?(view, "#arquivo-#{missing.id} button[phx-click=unquarantine]")
    refute has_element?(view, "#arquivo-#{available.id}")

    search_quarantine(view, "", "unknown")
    assert has_element?(view, "#arquivo-#{unknown.id}", "Pasta de origem desconhecida")
    refute has_element?(view, "#arquivo-#{unknown.id} button[phx-click=unquarantine]")
    refute has_element?(view, "#arquivo-#{missing.id}")

    view |> element("#clear-quarantine-filter") |> render_click()

    for track <- [available, missing, unknown],
        do: assert(has_element?(view, "#arquivo-#{track.id}"))
  end

  defp search_quarantine(view, query, availability) do
    view
    |> form("#quarantine-search", query: query, availability: availability)
    |> render_change()
  end

  defp quarantine_copy(title, artist, path, original) do
    track =
      insert(:track, status: :quarantined, tag_title: title, tag_artist: artist, rel_path: path)

    absolute = Path.join(Library.library_root(), path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "audio")

    if original do
      File.mkdir_p!(Path.dirname(Path.join(Library.library_root(), original)))

      {:ok, _op} =
        Operations.record(%{
          track_id: track.id,
          kind: :quarantine,
          status: :applied,
          from: original,
          to: path,
          batch_id: Uniq.UUID.uuid7()
        })
    end

    track
  end

  test "check_all reports how many tracks went to the queue", %{conn: conn} do
    insert(:track, status: :present, rel_path: "a.mp3")
    insert(:track, status: :present, rel_path: "b.mp3")

    {:ok, view, _html} = live(conn, ~p"/resgate")

    assert render_click(view, "check_all", %{}) =~ "Verificação de 2 faixa(s) enfileirada"
  end
end
