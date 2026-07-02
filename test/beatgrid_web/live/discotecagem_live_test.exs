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

    # headphone cue: per-deck PFL buttons + the routable phones output block
    assert html =~ "dj-pfl-a"
    assert html =~ "dj-pfl-b"
    assert html =~ "Fone (cue)"
    assert html =~ "dj-cue-device"
  end

  test "the transitions palette lists the classics and follows the AUTO switch", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/discotecagem")

    for {key, label} <- [
          {"cut", "Corte"},
          {"fade", "Fade"},
          {"crossfade", "Xfade"},
          {"echo", "Eco"},
          {"filter", "Filtro"},
          {"lowpass", "Afunda"},
          {"bass_swap", "Grave"},
          {"brake", "Freio"}
        ] do
      assert html =~ ~s(data-dj-fire="#{key}")
      assert html =~ label
    end

    # the live FX section: per-deck filter/echo/vinyl-tone + master punch + loops
    assert html =~ "Efeitos"
    assert html =~ "dj-filter-a"
    assert html =~ "dj-echofx-b"
    assert html =~ "dj-punch"
    assert html =~ "dj-tom-a"
    assert html =~ "dj-loop-b-4"

    # Serato-style waveform lanes at the top of the console
    assert html =~ "dj-wave-a"
    assert html =~ "dj-wave-b"

    # AUTO starts on; toggling flips the panel's guidance and tells the engine
    assert html =~ "AUTO ligado"
    html = render_click(view, "toggle_auto", %{})
    assert html =~ "clique dispara"
    assert_push_event(view, "dj_auto", %{on: false})
  end

  test "playing a set loads deck A and shows the queue with the pointer", %{conn: conn} do
    {set, [_a, _b]} = set_with_tracks([{"Abertura", 100.0}, {"Segunda", 104.0}])
    view = open_console(conn, set)

    html = render_click(view, "play_set", %{})

    assert html =~ "Abertura"
    # the queue tab shows live progress while the set plays
    assert html =~ "Fila 1/2"
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
        "playing_track_id" => a.id,
        "auto" => false,
        "set_id" => set.id
      })

    # pointer on Um, hint re-armed for Dois — and the CLIENT's auto state wins
    # (a remount must not force AUTO back on)
    assert html =~ "Um"
    assert html =~ "Dois"
    assert html =~ "Próxima"
    assert html =~ "clique dispara"
    assert Sets.entry_after(set.id, a.id).track.id == b.id
  end

  test "console_resync recovers the set itself after a remount wiped it", %{conn: conn} do
    {set, [a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    # fresh mount: NO set selected — the client still knows it
    {:ok, view, _html} = live(conn, ~p"/discotecagem")

    html =
      render_hook(view, "console_resync", %{
        "deck" => "a",
        "playing_track_id" => a.id,
        "auto" => true,
        "set_id" => set.id
      })

    # the set came back from the client and the hint chain resumed
    assert html =~ "Festa"
    assert html =~ "Dois"
    assert_push_event(view, "dj_hint", %{track: %{id: _}})
    _ = b
  end

  test "switching sets mid-play replaces the armed hint (or clears it)", %{conn: conn} do
    {set, [a, _b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_hint", %{track: %{title: "Dois"}})

    # a second set that does NOT contain the playing track
    {:ok, other} = Sets.create("Outro")
    extra = insert(:track, status: :present, tag_title: "Fora", duration_ms: 100_000)
    {:ok, _} = Sets.append(other, extra)

    render_change(view, "select_set", %{"set_id" => other.id})
    # the old set's hint cannot stay armed — playing track isn't in "Outro"
    assert_push_event(view, "dj_hint_clear", %{})
    _ = a
  end

  test "a transition into a non-set track never stamps the set on now-playing", %{conn: conn} do
    {set, [a, _b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    avulsa = insert(:track, status: :present, tag_title: "Avulsa", duration_ms: 90_000)
    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    render_hook(view, "transition_started", %{
      "from_track_id" => a.id,
      "to_track_id" => avulsa.id,
      "type" => "cut",
      "deck" => "b"
    })

    # the hint chain stops (library track has no successor in the set)
    assert_push_event(view, "dj_hint_clear", %{})
  end

  test "deck_error on the last playing track releases the idle state", %{conn: conn} do
    {set, [a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    # advance to the last track, then it errors: no next → clean idle
    render_hook(view, "transition_started", %{
      "from_track_id" => a.id,
      "to_track_id" => b.id,
      "type" => "cut",
      "deck" => "b"
    })

    html = render_hook(view, "deck_error", %{"deck" => "b", "track_id" => b.id})
    assert html =~ "Sem próxima armada"
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

  test "the biblioteca tab searches the whole library and loads onto a deck", %{conn: conn} do
    insert(:track,
      status: :present,
      tag_title: "Asa Branca",
      tag_artist: "Luiz Gonzaga",
      norm_title: "asa branca",
      norm_artist: "luiz gonzaga"
    )

    insert(:track,
      status: :present,
      tag_title: "Qui Nem Jiló",
      tag_artist: "Luiz Gonzaga",
      norm_title: "qui nem jilo",
      norm_artist: "luiz gonzaga"
    )

    {:ok, view, html} = live(conn, ~p"/discotecagem")

    # tabs render; fila is the default
    assert html =~ "Fila do set"
    assert html =~ "Biblioteca"

    # the browse-knob press toggles to the library, listing tracks with no set
    html = render_hook(view, "toggle_rail_tab", %{})
    assert html =~ "Asa Branca"
    assert html =~ "Qui Nem Jiló"

    # searching narrows the list
    html = render_change(view, "search_library", %{"q" => "asa"})
    assert html =~ "Asa Branca"
    refute html =~ "Qui Nem Jiló"

    # loading a library track works without any set selected
    track = Beatgrid.Repo.get_by!(Beatgrid.Library.Track, tag_title: "Asa Branca")
    render_click(view, "load_deck", %{"deck" => "b", "track_id" => track.id})
    assert_push_event(view, "dj_load", %{deck: "b", track: %{title: "Asa Branca"}})
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
