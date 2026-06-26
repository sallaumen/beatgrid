defmodule BeatgridWeb.TrackLiveAnalysisTest do
  # async: false — auto-analysis runs an async task that talks to the (globally
  # stubbed) analyzer mock and the shared sandbox.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.Tracks

  setup :set_mox_global

  test "auto-analyzes a track with no local analysis, then shows both sources", %{conn: conn} do
    stub(Beatgrid.Audio.AnalyzerMock, :analyze, fn _path ->
      {:ok, %{bpm: 92.0, key: 9, mode: 0}}
    end)

    song = insert(:soundcharts_song, camelot: "5A", tempo_bpm: 180.0)
    track = insert(:track, status: :present, soundcharts_song_id: song.id)

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    html = render_async(view)

    reloaded = Tracks.get(track.id)
    assert reloaded.bpm_detected == 92.0
    assert reloaded.camelot_detected == "8A"

    assert html =~ "Detectado (local)"
    assert html =~ "92"
    # 180 (Soundcharts) vs 92 (local) ≈ 2x → discrepancy flagged
    assert html =~ "divergem"
  end

  test "the re-analyze button re-runs the analysis", %{conn: conn} do
    stub(Beatgrid.Audio.AnalyzerMock, :analyze, fn _path ->
      {:ok, %{bpm: 100.0, key: 0, mode: 1}}
    end)

    track =
      insert(:track, status: :present, analyzed_at: ~U[2026-01-01 00:00:00Z], bpm_detected: 70.0)

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=reanalyze]") |> render_click()
    render_async(view)

    assert Tracks.get(track.id).bpm_detected == 100.0
  end
end
