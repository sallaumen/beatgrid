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

  describe "markers" do
    alias Beatgrid.Library.Tracks

    test "now_playing pushes the track's cue points to the hook", %{conn: conn} do
      track = insert(:track, tag_title: "M", cue_points: [%{"ms" => 5000, "label" => "intro"}])
      {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)

      render_hook(view, "now_playing", %{"id" => track.id})

      assert_push_event(view, "player_markers", %{markers: [%{"ms" => 5000, "label" => "intro"}]})
    end

    test "add_marker stores a cue at the live position on the now-playing track", %{conn: conn} do
      track = insert(:track, tag_title: "M")
      {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
      render_hook(view, "now_playing", %{"id" => track.id})

      render_hook(view, "add_marker", %{"ms" => 12_345})

      assert [%{"ms" => 12_345}] = Tracks.get(track.id).cue_points
      assert_push_event(view, "player_markers", %{markers: [%{"ms" => 12_345}]})
    end

    test "rename_marker and remove_marker manage cues on the now-playing track", %{conn: conn} do
      track = insert(:track, tag_title: "M", cue_points: [%{"ms" => 7000, "label" => nil}])
      {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
      render_hook(view, "now_playing", %{"id" => track.id})

      render_hook(view, "rename_marker", %{"ms" => "7000", "label" => "build"})
      assert Enum.find(Tracks.get(track.id).cue_points, &(&1["ms"] == 7000))["label"] == "build"

      render_hook(view, "remove_marker", %{"ms" => "7000"})
      assert Tracks.get(track.id).cue_points == []
    end

    test "toggle_markers opens the popover listing the cues", %{conn: conn} do
      track = insert(:track, tag_title: "M", cue_points: [%{"ms" => 90_000, "label" => "refrão"}])
      {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
      render_hook(view, "now_playing", %{"id" => track.id})

      html = render_click(view, "toggle_markers")

      assert html =~ "refrão"
      assert html =~ "1:30"
    end

    test "add_marker with nothing playing is a no-op", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)

      render_hook(view, "add_marker", %{"ms" => 1000})

      assert Playback.now_playing().track_id == nil
    end

    test "marker events ignore empty/non-numeric ms instead of crashing", %{conn: conn} do
      track = insert(:track, tag_title: "M", cue_points: [%{"ms" => 1000, "label" => nil}])
      {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
      render_hook(view, "now_playing", %{"id" => track.id})

      # These would crash a naive String.to_integer/trunc — the handler must no-op.
      render_hook(view, "rename_marker", %{"ms" => "", "label" => "x"})
      render_hook(view, "remove_marker", %{"ms" => "abc"})
      render_hook(view, "add_marker", %{"ms" => "not-a-number"})

      assert render(view) =~ "M"
      assert [%{"ms" => 1000}] = Tracks.get(track.id).cue_points
    end

    test "a marker mutation broadcasts markers_changed so other pages refresh", %{conn: conn} do
      track = insert(:track, tag_title: "M")
      Playback.subscribe_markers()
      {:ok, view, _html} = live_isolated(conn, BeatgridWeb.PlayerLive)
      render_hook(view, "now_playing", %{"id" => track.id})

      render_hook(view, "add_marker", %{"ms" => 4000})

      assert_receive {:markers_changed, id}
      assert id == track.id
    end
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
