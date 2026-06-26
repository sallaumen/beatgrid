defmodule BeatgridWeb.PlayerLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  test "renders the audio element and starts hidden", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, BeatgridWeb.PlayerLive)
    assert html =~ ~s(id="player-audio")
    assert html =~ "hidden"
  end

  test "now_playing renders the track's metadata and a link to its page", %{conn: conn} do
    track = insert(:track, tag_title: "Sina", tag_artist: "Djavan")
    {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)

    html = render_hook(view, "now_playing", %{"id" => track.id})

    assert html =~ "Sina"
    assert html =~ "Djavan"
    assert html =~ "/track/#{track.id}"
  end

  test "close clears the current track", %{conn: conn} do
    track = insert(:track, tag_title: "Sina", tag_artist: "Djavan")
    {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
    render_hook(view, "now_playing", %{"id" => track.id})

    html = render_click(view, "close")

    refute html =~ "Sina"
  end

  describe "sticky mount" do
    test "the global player is rendered on each page", %{conn: conn} do
      track = insert(:track, status: :present)

      for path <- ["/", "/revisao", "/painel", "/set", "/track/#{track.id}"] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ ~s(id="player-audio")
      end
    end
  end
end
