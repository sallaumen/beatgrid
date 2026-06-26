defmodule BeatgridWeb.ReviewLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.NameSync
  alias Beatgrid.Organization

  setup do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    :ok
  end

  defp pending_rename do
    song = insert(:soundcharts_song, credit_name: "Djavan", name: "Sina")

    insert(:track,
      filename: "old.mp3",
      rel_path: "MPB/old.mp3",
      tag_title: "Sina",
      tag_artist: "Djavan",
      soundcharts_song_id: song.id,
      sc_match_confidence: :high
    )

    {:ok, _} = NameSync.propose()
    [r] = NameSync.list_by(status: :pending)
    r
  end

  defp approve_btn(id), do: "button[phx-click=approve][phx-value-id='#{id}']"

  test "shows the three tabs and a pending rename card", %{conn: conn} do
    pending_rename()

    {:ok, _view, html} = live(conn, ~p"/revisao")

    assert html =~ "Central de Revisão"
    assert html =~ "Renomeações"
    assert html =~ "Classificação"
    assert html =~ "Auditoria"
    assert html =~ "Djavan - Sina.mp3"
    # preview player + per-card play button
    assert html =~ ~s(id="review-player")
    assert html =~ "Tocar (a partir dos 20s)"
  end

  test "approve toggles the card into the approved state and lifts the apply count", %{conn: conn} do
    r = pending_rename()
    {:ok, view, _html} = live(conn, ~p"/revisao")

    refute render(view) =~ "Aplicar 1 no disco"

    html = view |> element(approve_btn(r.id)) |> render_click()
    assert html =~ "Aplicar 1 no disco"
    assert NameSync.get(r.id).status == :approved

    view |> element(approve_btn(r.id)) |> render_click()
    assert NameSync.get(r.id).status == :pending
  end

  test "editing a rename updates the proposed filename and approves it", %{conn: conn} do
    r = pending_rename()
    {:ok, view, _html} = live(conn, ~p"/revisao")

    view |> element("button[phx-click=edit_start][phx-value-id='#{r.id}']") |> render_click()

    view
    |> form("#edit-#{r.id}", %{value: "Custom - Name.mp3", sid: r.id, type: "rename"})
    |> render_submit()

    edited = NameSync.get(r.id)
    assert edited.to_filename == "Custom - Name.mp3"
    assert edited.status == :approved
  end

  test "the classification tab shows AI suggestions with their rationale", %{conn: conn} do
    t =
      insert(:track, rel_path: "_Inbox/x.mp3", filename: "x.mp3", tag_title: "X", tag_artist: "Y")

    {:ok, _} =
      Organization.create_suggestion(%{
        track_id: t.id,
        from_rel_path: "_Inbox/x.mp3",
        to_genre_folder: "mpb",
        source: :claude,
        confidence: 0.92,
        reason: "soa como MPB"
      })

    {:ok, view, _html} = live(conn, ~p"/revisao")

    html = view |> element("button[phx-value-tab=classifications]") |> render_click()
    assert html =~ "soa como MPB"
    assert html =~ "IA:"
  end

  test "the auditoria tab lists flagged renames and dismisses a flag", %{conn: conn} do
    r = pending_rename()
    {:ok, _} = NameSync.set_reason(r, "[audit:verify/title] soundcharts: Djavan - Sina")

    {:ok, view, _html} = live(conn, ~p"/revisao")

    html = view |> element("button[phx-value-tab=auditoria]") |> render_click()
    assert html =~ "verify/title"

    view |> element("button[phx-click=dismiss_audit][phx-value-id='#{r.id}']") |> render_click()

    refute NameSync.get(r.id).reason =~ "[audit:"
    refute render(view) =~ "verify/title"
  end
end
