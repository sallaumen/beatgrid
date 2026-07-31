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

  # The scratch engine lives entirely in the `.DjConsole` colocated hook, which
  # wires itself to these elements by id at mount. When a layout change moves the
  # scratch panel around the DOM (as the viewport-fit work did), nothing tells us
  # if an id was dropped or renamed — the hook just silently fails to bind and the
  # whole scratch (and the console around it) goes dead with no server error. This
  # pins the id contract the hook depends on so any future merge that breaks it
  # fails here instead of on Lucas's controller mid-set.
  test "the scratch panel renders every element the DjConsole hook binds to", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/discotecagem")

    # the hook itself must be wired on the console root
    assert html =~ ~s(id="dj-console")
    assert html =~ "phx-hook"

    # scratch controls (auto-scratch pad, speed, crossfader, target readout)
    for id <- ~w(dj-scratch dj-scratch-pad dj-scratch-rate dj-scratch-xfader dj-scratch-target) do
      assert html =~ ~s(id="#{id}"),
             "missing scratch element ##{id} — the DjConsole hook binds it"
    end

    # the three auto-scratch pattern buttons the hook lights up by data attribute
    assert html =~ "data-dj-scratch-pat"

    # the deck audio + jog + waveform the real (jog) scratch reads back and forth
    for id <- ~w(dj-audio-a dj-audio-b dj-jog-a dj-jog-b dj-wave-a dj-wave-b) do
      assert html =~ ~s(id="#{id}"),
             "missing deck element ##{id} — scratch reads it back and forth"
    end

    # the crossfader curve toggle (Suave ↔ Seco cut) the hook binds for clean cuts
    assert html =~ ~s(id="dj-xfader-curve"), "missing the crossfader curve toggle"

    # trip-mode overlay + toggle: the hook paints and drives these by id
    for id <- ~w(dj-trip dj-trip-toggle trip-title trip-next trip-countdown trip-auto) do
      assert html =~ ~s(id="#{id}"), "missing trip element ##{id} — the DjConsole hook drives it"
    end
  end

  test "✈ Checar runs the pre-trip check and the report can be dismissed", %{conn: conn} do
    {set, [_a, _b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)

    html = render_click(view, "preflight", %{})
    # fixture tracks have no files on disk, so the check flags them
    assert html =~ "faixas com pendência"
    assert html =~ "arquivo sumido do disco"

    html = render_click(view, "close_preflight", %{})
    refute html =~ "faixas com pendência"
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

    # the shortcut-feedback toast pill (hook-owned, hidden by default)
    assert html =~ "dj-toast"

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

  test "a hand fire (T/viagem) teaches the pair its REAL point; palette and ended don't",
       %{conn: conn} do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Tres", 108.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    # derived from = 150s (the outro); firing at 120s is a 30s human correction
    html =
      render_hook(view, "transition_started", %{
        "from_track_id" => a.id,
        "to_track_id" => b.id,
        "type" => "echo",
        "deck" => "b",
        "origin" => "hint",
        "at_ms" => 120_000
      })

    assert html =~ "Ponto aprendido"
    entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
    assert entry_b.transition["learned_from_ms"] == 120_000

    # a palette fire has no pair intent; a dry "ended" cut is the track dying,
    # not a choice — neither may overwrite the pair's timing
    for origin <- ["palette", "ended"] do
      render_hook(view, "transition_started", %{
        "from_track_id" => b.id,
        "to_track_id" => c.id,
        "type" => "cut",
        "deck" => "a",
        "origin" => origin,
        "at_ms" => 120_000
      })
    end

    entry_c = Enum.find(Sets.entries(set), &(&1.track.id == c.id))
    refute Map.has_key?(entry_c.transition, "learned_from_ms")
  end

  test "transition_cancelled rewinds the pointer and re-arms the original hint", %{conn: conn} do
    {set, [a, b, _c]} =
      set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Tres", 108.0}])

    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_hint", %{track: %{title: "Dois"}})

    render_hook(view, "transition_started", %{
      "from_track_id" => a.id,
      "to_track_id" => b.id,
      "type" => "crossfade",
      "deck" => "b"
    })

    assert_push_event(view, "dj_hint", %{track: %{title: "Tres"}})

    html = render_hook(view, "transition_cancelled", %{"track_id" => a.id, "deck" => "a"})

    # the rescued track is the pointer again and Dois is the armed hint once more
    assert html =~ "Fila 1/3"
    assert_push_event(view, "dj_hint", %{track: %{title: "Dois"}})
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

  describe "played + set-membership tracking" do
    test "the fila marks a track as tocada once it goes on air", %{conn: conn} do
      {set, [a, _b]} = set_with_tracks([{"Track A", 120.0}, {"Track B", 122.0}])
      view = open_console(conn, set)

      refute render(view) =~ "tocada"

      html = render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id})
      assert html =~ "tocada"
    end

    test "the biblioteca tags set members ('no set') and played tracks ('tocada')", %{conn: conn} do
      {set, _tracks} = set_with_tracks([{"Membro do set", 120.0}, {"Outro membro", 122.0}])

      lib =
        insert(:track,
          status: :present,
          tag_title: "Só na biblioteca",
          tag_artist: "Fulano",
          norm_title: "so na biblioteca",
          norm_artist: "fulano"
        )

      view = open_console(conn, set)
      render_hook(view, "toggle_rail_tab", %{})
      html = render_change(view, "search_library", %{"q" => ""})

      # a set member shows the "no set" tag; nothing played yet
      assert html =~ "no set"
      refute html =~ "tocada"

      # playing the library-only track tags it "tocada" in the library
      html = render_hook(view, "deck_started", %{"deck" => "a", "track_id" => lib.id})
      assert html =~ "tocada"
    end

    test "switching sets clears the tocada tracking", %{conn: conn} do
      {set1, [a, _]} = set_with_tracks([{"S1 A", 120.0}, {"S1 B", 122.0}])
      {set2, _} = set_with_tracks([{"S2 A", 121.0}, {"S2 B", 123.0}])

      view = open_console(conn, set1)
      assert render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id}) =~ "tocada"

      # a new set resets the played history — the rules start over for its tracks
      html = render_change(view, "select_set", %{"set_id" => set2.id})
      refute html =~ "tocada"
    end
  end
end
