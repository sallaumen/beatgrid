defmodule BeatgridWeb.RescueLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Beatgrid.Factory
  import Phoenix.LiveViewTest

  alias Beatgrid.Library
  alias Beatgrid.Operations

  setup :isolate_library_root

  test "renders the census and the empty states", %{conn: conn} do
    insert(:track, status: :present, rel_path: "ok.mp3", integrity_status: :ok)

    {:ok, _view, html} = live(conn, ~p"/resgate")

    assert html =~ "Resgate"
    assert html =~ "íntegras"
    assert html =~ "Nenhuma faixa danificada conhecida"
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

    {:ok, _view, html} = live(conn, ~p"/resgate")

    assert html =~ "Hora do Adeus"
    assert html =~ "arquivo sumido"
    assert html =~ "Restaurar do backup"
    assert html =~ "Restaurar todas com backup (1)"
    assert html =~ "Dupla Esquecida"
    assert html =~ "Forró/dupla.mp3"
  end

  test "check_all reports how many tracks went to the queue", %{conn: conn} do
    insert(:track, status: :present, rel_path: "a.mp3")
    insert(:track, status: :present, rel_path: "b.mp3")

    {:ok, view, _html} = live(conn, ~p"/resgate")

    assert render_click(view, "check_all", %{}) =~ "Verificando 2 faixa(s)"
  end
end
