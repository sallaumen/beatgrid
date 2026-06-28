defmodule BeatgridWeb.MixLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

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
end
