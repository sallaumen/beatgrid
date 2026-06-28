defmodule BeatgridWeb.ReviewLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Mox
  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.NameSync
  alias Beatgrid.Organization

  setup do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    :ok
  end

  defp pending_rename do
    song =
      insert(:soundcharts_song,
        credit_name: "Djavan",
        name: "Sina",
        image_url: "https://img.test/cover.jpg"
      )

    track =
      insert(:track,
        filename: "old.mp3",
        rel_path: "MPB/old.mp3",
        tag_title: "Sina",
        tag_artist: "Djavan",
        soundcharts_song_id: song.id,
        sc_match_confidence: :high
      )

    {:ok, _} = NameSync.propose()
    NameSync.list_by(status: :pending) |> Enum.find(&(&1.track_id == track.id))
  end

  defp pending_low_rename do
    song = insert(:soundcharts_song, credit_name: "Bola", name: "Sete")

    track =
      insert(:track,
        filename: "z.mp3",
        rel_path: "MPB/z.mp3",
        soundcharts_song_id: song.id,
        sc_match_confidence: :low
      )

    {:ok, _} = NameSync.propose()
    NameSync.list_by(status: :pending) |> Enum.find(&(&1.track_id == track.id))
  end

  defp select_btn(id), do: "button[phx-click=toggle_select][phx-value-id='#{id}']"

  test "shows the three tabs and a pending rename card", %{conn: conn} do
    pending_rename()

    {:ok, _view, html} = live(conn, ~p"/revisao")

    assert html =~ "Central de Revisão"
    assert html =~ "Renomeações"
    assert html =~ "Classificação"
    assert html =~ "Auditoria"
    assert html =~ "Djavan - Sina.mp3"
    # global player present; no local review-player
    assert html =~ ~s(id="player-audio")
    refute html =~ ~s(id="review-player")
    # album art on the card
    assert html =~ "https://img.test/cover.jpg"
  end

  test "reserves space for the fixed bottom player (no full-height occlusion)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/revisao")

    # Must leave 5rem for the fixed bottom player, like every other viewport-filling
    # screen — the old "flex h-screen flex-col" container pushed the bottom actions
    # behind the player (app_shell's own min-h-screen wrapper is fine, hence the
    # targeted pattern rather than a bare "h-screen").
    assert html =~ "h-[calc(100vh_-_5rem)]"
    refute html =~ "flex h-screen"
  end

  test "marking a card lifts the apply count without touching its DB status", %{conn: conn} do
    r = pending_rename()
    {:ok, view, _html} = live(conn, ~p"/revisao")

    refute render(view) =~ "Aplicar 1 no disco"

    html = view |> element(select_btn(r.id)) |> render_click()
    assert html =~ "Aplicar 1 no disco"
    # the key fix: selecting is ephemeral — it must NOT mutate the row (no reorder/reload)
    assert NameSync.get(r.id).status == :pending

    view |> element(select_btn(r.id)) |> render_click()
    refute render(view) =~ "Aplicar 1 no disco"
  end

  test "Selecionar todas marks every card in the tab", %{conn: conn} do
    pending_rename()
    pending_low_rename()
    {:ok, view, _html} = live(conn, ~p"/revisao")

    html = view |> element("button[phx-click=select_all]") |> render_click()
    assert html =~ "Aplicar 2 no disco"
  end

  test "Selecionar alta confiança marks only high-confidence cards", %{conn: conn} do
    pending_rename()
    pending_low_rename()
    {:ok, view, _html} = live(conn, ~p"/revisao")

    html = view |> element("button[phx-click=select_high]") |> render_click()
    assert html =~ "Aplicar 1 no disco"
  end

  test "Limpar clears the current selection", %{conn: conn} do
    pending_rename()
    pending_low_rename()
    {:ok, view, _html} = live(conn, ~p"/revisao")

    view |> element("button[phx-click=select_all]") |> render_click()
    html = view |> element("button[phx-click=clear_selection]") |> render_click()
    refute html =~ "Aplicar 2 no disco"
  end

  test "editing a rename updates the proposed filename and marks the card", %{conn: conn} do
    r = pending_rename()
    {:ok, view, _html} = live(conn, ~p"/revisao")

    view |> element("button[phx-click=edit_start][phx-value-id='#{r.id}']") |> render_click()

    view
    |> form("#edit-#{r.id}", %{value: "Custom - Name.mp3", sid: r.id, type: "rename"})
    |> render_submit()

    assert NameSync.get(r.id).to_filename == "Custom - Name.mp3"
    assert render(view) =~ "Aplicar 1 no disco"
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

  test "card play controls target the global player", %{conn: conn} do
    pending_rename()
    {:ok, _view, html} = live(conn, ~p"/revisao")
    assert html =~ "beatgrid:play"
    assert html =~ "#player-audio"
    refute html =~ ~s(id="review-player")
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

  test "a scope click enqueues a ReevaluateWorker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/revisao")

    view
    |> element("button[phx-click='reevaluate'][phx-value-scope='unevaluated']")
    |> render_click()

    assert [job] = all_enqueued(worker: Beatgrid.Workers.ReevaluateWorker)
    assert job.args["scope"] == "unevaluated"
  end

  test "a progress tick renders the live progress bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/revisao")

    send(
      view.pid,
      {:reevaluate_progress, %{batch_id: "b1", status: :running, done: 3, total: 10}}
    )

    assert render(view) =~ "3/10"
  end

  test "re-avaliar com IA updates a rename suggestion's name via job + progress", %{conn: conn} do
    pending_rename()

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "resolutions" => [
           %{
             "index" => 1,
             "same_recording" => false,
             "artist" => "Forró In The Dark",
             "title" => "Cajuína",
             "confidence" => 0.7,
             "rationale" => "versão forró"
           }
         ]
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/revisao")
    view |> element("button[phx-click='reevaluate'][phx-value-scope='pending']") |> render_click()

    [job] = all_enqueued(worker: Beatgrid.Workers.ReevaluateWorker)
    perform_job(Beatgrid.Workers.ReevaluateWorker, job.args)

    html = render(view)
    assert html =~ "Forró In The Dark - Cajuína"
  end
end
