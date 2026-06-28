defmodule BeatgridWeb.MixLiveTest do
  use BeatgridWeb.ConnCase, async: true, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Normalize
  alias Beatgrid.Mixes.Segment
  alias Beatgrid.Repo
  alias Beatgrid.Workers.MixAnalyzeWorker

  test "renders the segment timeline with names, BPM, Camelot and the transition map", %{
    conn: conn
  } do
    track = insert(:track, status: :present, tag_artist: "A", tag_title: "One")
    mix = insert(:mix, title: "Live Set", dj: "DJ X", status: :ready)

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      artist: "A",
      title: "One",
      bpm_detected: 124.0,
      camelot_detected: "8A",
      matched_track_id: track.id,
      match_confidence: :high
    )

    insert(:mix_segment,
      mix: mix,
      position: 1,
      start_ms: 270_000,
      artist: "B",
      title: "Two",
      bpm_detected: 126.0,
      camelot_detected: "9A"
    )

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")

    assert html =~ "Live Set"
    assert html =~ "A" and html =~ "One" and html =~ "Two"
    assert html =~ "8A" and html =~ "9A"
    # 270_000 ms as mm:ss
    assert html =~ "04:30"
    # matched segment badge
    assert html =~ "tenho"
    assert html =~ "/track/#{track.id}"
  end

  test "redirects to the index when the mix is missing", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/sets-online"}}} =
             live(conn, ~p"/sets-online/#{Ecto.UUID.generate()}")
  end

  test "editing a segment name persists and re-matches the library", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_artist: "Djavan",
        tag_title: "Sina",
        norm_artist: Normalize.normalize("Djavan"),
        norm_title: Normalize.normalize("Sina")
      )

    mix = insert(:mix, status: :ready)
    seg = insert(:mix_segment, mix: mix, position: 0, start_ms: 0, artist: nil, title: nil)

    {:ok, view, _html} = live(conn, ~p"/sets-online/#{mix.id}")

    view
    |> form("#seg-form-#{seg.id}", %{artist: "Djavan", title: "Sina"})
    |> render_submit()

    reloaded = Repo.get(Segment, seg.id)
    assert reloaded.artist == "Djavan" and reloaded.name_source == :manual
    assert reloaded.matched_track_id == track.id
  end

  test "Re-analisar re-enqueues the analyze worker", %{conn: conn} do
    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/m.mp3")
    {:ok, view, _html} = live(conn, ~p"/sets-online/#{mix.id}")

    view |> element("button[phx-click=reanalyze]") |> render_click()
    assert_enqueued(worker: MixAnalyzeWorker, args: %{mix_id: mix.id})
  end

  test "renders DJ section headers when dj parts exist", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, title: "T1")
    insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ A", source: :manual)

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ "DJ A"
  end

  test "manual timestamps create dj sections", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)

    {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
    render_submit(element(view, "#dj-manual-form"), %{"timestamps" => "0:00 A\n5:00 B"})
    assert render(view) =~ "A" and render(view) =~ "B"
  end
end
