defmodule BeatgridWeb.PlayerLiveTest do
  # async: false — the handlers update the global NowPlaying pointer.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.{Playback, Sets}

  setup do
    Playback.clear_now_playing()
    on_exit(&Playback.clear_now_playing/0)
    :ok
  end

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

  test "now_playing with a set stores the pointer and shows a chip linking to the set", %{
    conn: conn
  } do
    track = insert(:track, tag_title: "Asa Branca", tag_artist: "Luiz")
    {:ok, set} = Sets.create("Raízes")
    {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)

    html = render_hook(view, "now_playing", %{"id" => track.id, "set_id" => set.id})

    assert html =~ "Asa Branca"
    assert html =~ "Raízes"
    assert html =~ "/set/#{set.id}"
    assert Playback.now_playing() == %{track_id: track.id, set_id: set.id}
  end

  test "track_ended advances to the next track in the set (the pointer)", %{conn: conn} do
    {:ok, set} = Sets.create("Chain")
    a = insert(:track, tag_title: "First", status: :present)
    b = insert(:track, tag_title: "Second", status: :present)
    {:ok, _} = Sets.append(set, a)
    {:ok, _} = Sets.append(set, b)

    {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
    render_hook(view, "now_playing", %{"id" => a.id, "set_id" => set.id})

    render_hook(view, "track_ended", %{})

    assert_push_event(view, "play_track", %{id: next_id})
    assert next_id == b.id
    assert render(view) =~ "Second"
    assert Playback.now_playing() == %{track_id: b.id, set_id: set.id}
  end

  test "track_ended at the end of the set drops the set context", %{conn: conn} do
    {:ok, set} = Sets.create("Solo")
    a = insert(:track, tag_title: "Only", status: :present)
    {:ok, _} = Sets.append(set, a)

    {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
    render_hook(view, "now_playing", %{"id" => a.id, "set_id" => set.id})

    html = render_hook(view, "track_ended", %{})

    refute html =~ "/set/#{set.id}"
    assert Playback.now_playing() == %{track_id: a.id, set_id: nil}
  end

  test "now_playing with an unknown track id clears the pointer (no ghost highlight)", %{
    conn: conn
  } do
    track = insert(:track, tag_title: "Real")
    {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
    render_hook(view, "now_playing", %{"id" => track.id})
    assert Playback.now_playing().track_id == track.id

    render_hook(view, "now_playing", %{"id" => "00000000-0000-0000-0000-000000000000"})
    assert Playback.now_playing() == %{track_id: nil, set_id: nil}
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
