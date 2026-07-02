defmodule BeatgridWeb.DiscotecagemLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Sets

  defp set_with_tracks(names_bpms) do
    {:ok, set} = Sets.create("Festa")

    tracks =
      for {title, bpm} <- names_bpms do
        track =
          insert(:track,
            status: :present,
            tag_title: title,
            bpm_detected: bpm,
            duration_ms: 200_000,
            cue_points: [%{"ms" => 150_000, "type" => "outro", "source" => "auto"}]
          )

        {:ok, _} = Sets.append(set, track)
        track
      end

    {:ok, _} = Sets.connect_all(set)
    {set, tracks}
  end

  defp open_console(conn, set) do
    {:ok, view, _html} = live(conn, ~p"/discotecagem")
    render_change(view, "select_set", %{"set_id" => set.id})
    view
  end

  test "renders the console: decks, mixer, and the set picker", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/discotecagem")

    assert html =~ "Discotecagem"
    assert html =~ "Deck A"
    assert html =~ "Deck B"
    assert html =~ "Crossfader"
    assert html =~ "Controladora MIDI"
    assert html =~ "Escolher set…"
  end

  test "the transitions palette lists the classics and follows the AUTO switch", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/discotecagem")

    for {key, label} <- [
          {"cut", "Corte"},
          {"fade", "Fade"},
          {"crossfade", "Xfade"},
          {"echo", "Eco"},
          {"filter", "Filtro"},
          {"bass_swap", "Grave"},
          {"brake", "Freio"}
        ] do
      assert html =~ ~s(data-dj-fire="#{key}")
      assert html =~ label
    end

    # AUTO starts on; toggling flips the panel's guidance and tells the engine
    assert html =~ "AUTO ligado"
    html = render_click(view, "toggle_auto", %{})
    assert html =~ "Modo manual"
    assert_push_event(view, "dj_auto", %{on: false})
  end

  test "playing a set loads deck A and shows the queue with the pointer", %{conn: conn} do
    {set, [_a, _b]} = set_with_tracks([{"Abertura", 100.0}, {"Segunda", 104.0}])
    view = open_console(conn, set)

    html = render_click(view, "play_set", %{})

    assert html =~ "Abertura"
    assert html =~ "Fila do set"
    # the next entry is announced in the mixer's next-up card
    assert html =~ "Próxima"
    assert html =~ "Segunda"

    # the client gets the first track (autoplay) and the revocable hint
    assert_push_event(view, "dj_load", %{deck: "a", autoplay: true, track: %{title: "Abertura"}})
    assert_push_event(view, "dj_hint", %{track: %{title: "Segunda"}})
  end

  test "transition_started advances the pointer and re-arms the following hint", %{conn: conn} do
    {set, [a, b, c]} =
      set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Tres", 108.0}])

    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    html =
      render_hook(view, "transition_started", %{
        "from_track_id" => a.id,
        "to_track_id" => b.id,
        "type" => "echo",
        "deck" => "b"
      })

    # pointer moved to Dois; the new hint announces Tres
    assert html =~ "Dois"
    assert html =~ "Tres"
    assert Sets.entry_after(set.id, b.id).track.id == c.id
  end

  test "editing the set live refreshes the queue rendering", %{conn: conn} do
    {set, [_a, _b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    extra =
      insert(:track,
        status: :present,
        tag_title: "Convidada",
        bpm_detected: 102.0,
        duration_ms: 180_000
      )

    {:ok, _} = Sets.append(set, extra)

    assert render(view) =~ "Convidada"
  end

  test "console_resync adopts the client's playing state", %{conn: conn} do
    {set, [a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)

    html =
      render_hook(view, "console_resync", %{
        "deck" => "a",
        "playing_track_id" => a.id
      })

    # pointer on Um, hint re-armed for Dois
    assert html =~ "Um"
    assert html =~ "Dois"
    assert html =~ "Próxima"
    assert Sets.entry_after(set.id, a.id).track.id == b.id
  end

  test "a deck error on the idle deck skips the failed entry in the hint", %{conn: conn} do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Tres", 108.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    # deck B (idle, preloading Dois) reports a media error → hint jumps to Tres
    html =
      render_hook(view, "deck_error", %{"deck" => "b", "track_id" => b.id})

    assert html =~ "Tres"
    assert Sets.entry_after(set.id, a.id).track.id == b.id
    _ = c
  end

  test "loading onto the audible deck is refused; the idle deck accepts", %{conn: conn} do
    {set, [_a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    # consume the legitimate start-of-set load before checking the refusal
    assert_push_event(view, "dj_load", %{deck: "a", autoplay: true})

    render_click(view, "load_deck", %{"deck" => "a", "track_id" => b.id})
    refute_push_event(view, "dj_load", %{deck: "a"})

    render_click(view, "load_deck", %{"deck" => "b", "track_id" => b.id})
    assert_push_event(view, "dj_load", %{deck: "b", autoplay: false})
  end

  test "track_ended clears the playing state (end of set keeps auto on)", %{conn: conn} do
    {set, [a, _b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    html = render_hook(view, "track_ended", %{"track_id" => a.id})

    assert html =~ "Sem próxima armada"
    # AUTO continues enabled for the next play
    assert html =~ "Auto"
  end
end
