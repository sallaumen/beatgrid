defmodule BeatgridWeb.TrackLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks

  test "shows the detail and updates rating, tags and note", %{conn: conn} do
    song = insert(:soundcharts_song, camelot: "8A", tempo_bpm: 120.0, energy: 0.6)

    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        soundcharts_song_id: song.id,
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Sina"
    assert html =~ "Metadados"

    view |> element(~s|button[phx-value-n="7"]|) |> render_click()
    assert Tracks.get(track.id).rating == 7

    view |> form("form[phx-submit=add_tag]", %{tag: "festa"}) |> render_submit()
    assert "festa" in Tracks.get(track.id).tags

    view |> element(~s|button[phx-value-tag="festa"]|) |> render_click()
    refute "festa" in Tracks.get(track.id).tags

    view |> form("form[phx-change=save_note]", %{note: "abertura"}) |> render_change()
    assert Tracks.get(track.id).personal_note == "abertura"
  end

  test "starts a set seeded with this track and navigates to /set", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=start_set]") |> render_click()

    assert_redirect(view, ~p"/set")
    assert [set] = Beatgrid.Sets.list()
    assert Enum.map(Beatgrid.Sets.tracks(set), & &1.id) == [track.id]
  end

  test "renders the waveform player and adds/removes a marker", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "X",
        tag_artist: "Y",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "track-waveform"
    assert html =~ ~s(phx-hook="Waveform")

    render_hook(view, "add_marker", %{"ms" => 30_000})
    assert [%{"ms" => 30_000}] = Tracks.get(track.id).cue_points
    assert render(view) =~ "0:30"

    view |> element("button[phx-click=remove_marker][phx-value-ms='30000']") |> render_click()
    assert Tracks.get(track.id).cue_points == []
  end

  test "redirects to the library when the track is not found", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/track/#{Ecto.UUID.generate()}")
  end

  test "renders the Atualizar metadados button with data-confirm", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Atualizar metadados"
    assert html =~ "phx-click=\"enrich_track\""
    assert html =~ "data-confirm"
  end

  test "shows YouTube video and playlist links when raw_tags present", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Disritmia",
        tag_artist: "Casuarina",
        analyzed_at: ~U[2026-01-01 00:00:00Z],
        raw_tags: %{
          "youtube_url" => "https://youtu.be/abc123",
          "youtube_playlist_url" => "https://youtube.com/playlist?list=PL1"
        }
      )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "https://youtu.be/abc123"
    assert html =~ "https://youtube.com/playlist?list=PL1"
    assert html =~ "Abrir vídeo"
    assert html =~ "Abrir playlist"
  end

  test "does not show YouTube rows when raw_tags has no youtube keys", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z],
        raw_tags: %{}
      )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    refute html =~ "Abrir vídeo"
    refute html =~ "Abrir playlist"
  end
end
