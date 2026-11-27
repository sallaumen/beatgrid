defmodule BeatgridWeb.DiscotecagemLiveTest do
  # The console reports a shared process-owned now-playing pointer.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Playback
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
    {:ok, view, html} = live(conn, ~p"/discotecagem")

    assert html =~ "Discotecagem"
    assert html =~ "Deck A"
    assert html =~ "Deck B"
    assert html =~ "Crossfader"
    assert html =~ "Controladora MIDI"
    assert html =~ "Escolher set…"

    # headphone cue: per-deck PFL buttons + the routable phones output block
    for deck <- ["a", "b"] do
      assert has_element?(
               view,
               ~s(#dj-pfl-#{deck}[aria-label="Pré-escuta do deck #{String.upcase(deck)}"][aria-pressed="false"])
             )
    end

    assert html =~ "Fone (cue)"
    assert has_element?(view, "#dj-out-device.h-8")
    assert has_element?(view, "#dj-cue-device.h-8")
  end

  test "both decks identify each pad and disable the empty deck's controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discotecagem")

    for deck <- ["a", "b"] do
      side = String.upcase(deck)

      for slot <- 1..4 do
        assert has_element?(
                 view,
                 "#dj-pad-#{deck}-#{slot}[disabled] .sr-only",
                 "Hot cue #{slot} do deck #{side}"
               )
      end

      for beats <- [1, 2, 4, 8] do
        unit = if beats == 1, do: "tempo", else: "tempos"

        assert has_element?(
                 view,
                 ~s(#dj-loops-#{deck}[disabled] #dj-loop-#{deck}-#{beats}[aria-label="Loop de #{beats} #{unit} no deck #{side}"][aria-pressed="false"])
               )
      end
    end
  end

  test "rehearsing opens a private comparison without binding a live transition", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discotecagem")

    assert has_element?(view, ~s(button[aria-controls="dj-rehearse-dialog"]), "Ensaiar a próxima")
    assert has_element?(view, "#dj-rehearse-dialog canvas[data-wave=out]")
    assert has_element?(view, "#dj-rehearse-dialog canvas[data-wave=in]")
    assert has_element?(view, "#dj-rehearse-dialog [data-timing]")

    assert has_element?(
             view,
             "#dj-room-score [data-score-panel][hidden]",
             "Último ensaio levado à pista"
           )

    assert has_element?(view, "#dj-rehearsal [data-reservation] + #dj-room-score")
    refute has_element?(view, "#dj-rehearse-dialog #dj-room-score")

    assert has_element?(
             view,
             "#dj-rehearse-dialog [data-cue-assist][hidden] [data-cue-check]",
             "Verificar encaixe"
           )

    assert has_element?(view, "#dj-rehearse-dialog [data-cue-try][hidden]", "Experimentar ajuste")
    assert has_element?(view, "#dj-rehearse-dialog [data-cue-restore][hidden]", "Restaurar CUE")
    assert has_element?(view, "#dj-rehearse-dialog [data-cue-note][aria-live=polite]")

    assert has_element?(
             view,
             "#dj-rehearse-dialog #dj-rehearsal-score [data-score-panel][hidden]"
           )

    for side <- ["out", "into"], key <- ["rate", "level", "tone", "filter"] do
      id = "rehearsal-#{side}-#{key}"
      assert has_element?(view, "#dj-rehearse-dialog label[for=#{id}]")
      assert has_element?(view, "#dj-rehearse-dialog input##{id}[data-mix=#{key}]")
    end

    assert has_element?(view, "#dj-rehearse-dialog input[value=cut]")
    assert has_element?(view, "#dj-rehearse-dialog input[value=blend]")

    for kind <- ["cut", "blend"] do
      assert has_element?(view, "#dj-rehearse-dialog label [data-score-for=#{kind}][hidden]")
    end

    assert has_element?(
             view,
             "#dj-rehearse-dialog button[data-listen][disabled]",
             "Ouvir no fone"
           )

    assert has_element?(view, "#dj-rehearse-dialog [data-arm][disabled]", "Armar esta passagem")

    assert has_element?(
             view,
             "[data-reservation][hidden] [data-confirm][disabled]",
             "Confirmar para a pista"
           )

    assert has_element?(view, "[data-reservation] [data-disarm]", "Desarmar")

    refute has_element?(
             view,
             "#dj-rehearse-dialog [data-dj-fire], #dj-rehearse-dialog [phx-click]"
           )
  end

  test "the two waveform lanes expose independent media status before a load", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discotecagem")

    for deck <- ["a", "b"] do
      assert has_element?(view, "#dj-waves #dj-media-status-#{deck}[role=status]", "Vazio")

      assert has_element?(
               view,
               ~s(#dj-wave-#{deck}[aria-label="Forma de onda do deck #{String.upcase(deck)}"])
             )
    end
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
    assert html =~ ~s(aria-haspopup="dialog")
    assert html =~ ~s(<dialog)

    for id <- ~w(dj-trip dj-trip-toggle trip-title trip-next trip-countdown trip-auto) do
      assert html =~ ~s(id="#{id}"), "missing trip element ##{id} — the DjConsole hook drives it"
    end
  end

  test "the preparation report follows the selected set and its disclosure button", %{conn: conn} do
    {set, _tracks} = set_with_tracks([{"Um", 100.0}])
    view = open_console(conn, set)

    view |> element("button[phx-click=preflight]") |> render_click()
    assert has_element?(view, ~s(button[aria-expanded=true][aria-controls=dj-preflight]))
    assert has_element?(view, "#dj-preflight", "arquivo sumido do disco")

    view |> element("button[aria-controls=dj-preflight]") |> render_click()
    refute has_element?(view, "#dj-preflight")
    assert has_element?(view, "button[phx-click=preflight][aria-expanded=false]")

    view |> element("button[phx-click=preflight]") |> render_click()
    view |> form("#dj-set-picker", %{set_id: ""}) |> render_change()
    refute has_element?(view, "#dj-preflight")
    refute has_element?(view, "button[phx-click=play_set]")
    assert has_element?(view, "button[phx-click=stop_all]")
  end

  test "an open preparation report follows edits in the set editor, including an emptied queue",
       %{conn: conn} do
    {set, [first]} = set_with_tracks([{"Abertura", 100.0}])
    view = open_console(conn, set)
    view |> element("button[phx-click=preflight]") |> render_click()
    assert has_element?(view, "#dj-preflight li", "Abertura")

    next = insert(:track, status: :present, tag_title: "Saideira")
    {:ok, _} = Sets.append(set, next)
    assert has_element?(view, "#dj-preflight li", "Saideira")
    :ok = Sets.remove(set, first)
    refute has_element?(view, "#dj-preflight li", "Abertura")

    :ok = Sets.remove(set, next)
    assert has_element?(view, "#dj-preflight", "O set está vazio.")
    refute has_element?(view, "#dj-preflight li")

    view |> element("button[aria-controls=dj-preflight]") |> render_click()
    {:ok, _} = Sets.append(set, first)
    assert has_element?(view, "#dj-queue-list li", "Abertura")
    refute has_element?(view, "#dj-preflight")
  end

  test "deleting the checked set in another tab disarms the queue and leaves the current track on air",
       %{conn: conn} do
    {set, [a, _b]} = set_with_tracks([{"Baião", 112.0}, {"Xote", 116.0}])
    view = open_console(conn, set)
    render_click(view, "play_set")
    render_hook(view, "deck_started", %{"track_id" => a.id, "deck" => "a"})
    render_click(view, "preflight")
    assert has_element?(view, "#dj-preflight")

    {:ok, _} = Sets.delete(set)
    assert_push_event(view, "dj_set", %{id: nil})
    assert_push_event(view, "dj_hint_clear", %{})
    refute has_element?(view, "#dj-preflight")
    refute has_element?(view, "#dj-set-picker option[value='#{set.id}']")
    assert Playback.now_playing() == %{track_id: a.id, set_id: nil}
  end

  test "deselecting the set does not take the identical pointer back from another player",
       %{conn: conn} do
    {set, [track]} = set_with_tracks([{"Baião", 112.0}])
    view = open_console(conn, set)
    render_click(view, "play_set")

    pointer = %{track_id: track.id, set_id: set.id}
    Playback.set_now_playing(pointer)

    view |> form("#dj-set-picker", %{set_id: ""}) |> render_change()
    assert_push_event(view, "dj_set", %{id: nil})
    assert Playback.now_playing() == pointer
  end

  test "automatic recovery loads belong to the selected set, not a later queue",
       %{conn: conn} do
    {set, [first, next]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    set_id = set.id
    next_id = next.id
    render_click(view, "play_set")
    assert_push_event(view, "dj_load", %{deck: "a", autoplay: true, set_id: ^set_id})

    render_hook(view, "deck_error", %{"deck" => "a", "track_id" => first.id})

    assert_push_event(view, "dj_load", %{
      deck: "b",
      autoplay: true,
      set_id: ^set_id,
      track: %{id: ^next_id}
    })

    view |> form("#dj-set-picker", %{set_id: ""}) |> render_change()
    assert_push_event(view, "dj_set", %{id: nil})
  end

  test "checking a set reports missing audio and the report can be dismissed", %{conn: conn} do
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
          {"brake", "Freio"},
          {"scratch_cut", "Rasgo"},
          {"spinback", "Rebob"},
          {"chirp", "Chirp"},
          {"transform", "Transf"},
          {"scribble", "Risca"}
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

  test "travel mode receives the same transition label as the booth and starts without playback",
       %{conn: conn} do
    {set, [_a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    {:ok, _} = Sets.connect(set, b, %{"type" => "cut"})
    view = open_console(conn, set)
    assert has_element?(view, "#trip-now-live #trip-transport-label", "Sem reprodução")
    render_click(view, "play_set", %{})

    assert_push_event(view, "dj_hint", %{
      transition: %{"type" => "cut"},
      transition_label: "CORTE"
    })
  end

  test "homonymous recordings remain identifiable in both decks, the queue, library and next card",
       %{conn: conn} do
    {:ok, set} = Sets.create("Duas versões")

    [a, b] =
      for path <- ["MPB/Sina - estúdio.mp3", "_Inbox/Sina - ao vivo.mp3"] do
        track =
          insert(:track,
            status: :present,
            tag_title: "Sina",
            tag_artist: "Djavan",
            rel_path: path,
            filename: Path.basename(path),
            bpm_detected: 100.0,
            duration_ms: 180_000,
            cue_points: [%{"ms" => 150_000, "type" => "outro", "source" => "auto"}]
          )

        {:ok, _} = Sets.append(set, track)
        track
      end

    view = open_console(conn, set)
    render_click(view, "play_set", %{})

    assert_push_event(view, "dj_load", %{
      track: %{rel_path: path_a, identity_key: ["sina", "djavan"]}
    })

    assert_push_event(view, "dj_hint", %{
      track: %{rel_path: path_b, identity_key: ["sina", "djavan"]}
    })

    assert {path_a, path_b} == {a.rel_path, b.rel_path}
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => b.id})

    for {deck, track} <- [{"a", a}, {"b", b}] do
      assert has_element?(view, "#dj-deck-#{deck} [data-version-path]", track.rel_path)

      assert has_element?(
               view,
               "#dj-deck-#{deck} a[href='/track/#{track.id}?set_id=#{set.id}'][target='_blank']"
             )

      assert has_element?(view, "#dj-queue-track-#{track.id} [data-version-path]", track.rel_path)

      assert has_element?(
               view,
               "#dj-library-track-#{track.id} [data-version-path]",
               track.rel_path
             )

      assert has_element?(
               view,
               "#dj-queue-track-#{track.id} [data-loaded-deck='#{deck}']",
               "Deck #{String.upcase(deck)}"
             )

      assert has_element?(
               view,
               "#dj-queue-track-#{track.id} button[phx-value-deck=a][aria-label*='#{track.rel_path}']"
             )
    end

    for track <- [a, b], rail <- ["queue", "library"] do
      assert has_element?(
               view,
               "#dj-#{rail}-track-#{track.id} a[href='/track/#{track.id}?set_id=#{set.id}'][target='_blank']"
             )
    end

    assert has_element?(view, "#dj-next-card [data-version-path]", b.rel_path)
    assert has_element?(view, "#trip-now-live[role=status][aria-live=polite] #trip-version")
    assert has_element?(view, "#trip-next-live[role=status][aria-live=polite] #trip-next-artist")
    assert has_element?(view, "#trip-next-live #trip-next-version")
    refute has_element?(view, "#trip-now-live #trip-pos")
    refute has_element?(view, "#trip-next-live #trip-countdown")
    assert has_element?(view, "#dj-next-card", "Fila #2")
    assert has_element?(view, "#dj-queue-list a[target='_blank']", "Sina")
    assert has_element?(view, "a[href='/set/#{set.id}'][target='_blank']", "Editar set")
  end

  test "a booth track consultation retains the active set context without disconnecting the booth",
       %{conn: conn} do
    {set, [_member]} = set_with_tracks([{"Membro", 100.0}])

    avulsa =
      insert(:track,
        status: :present,
        tag_title: "Avulsa",
        bpm_detected: 100.0,
        duration_ms: 180_000
      )

    view = open_console(conn, set)
    render_hook(view, "deck_loaded", %{"deck" => "b", "track_id" => avulsa.id})
    path = ~p"/track/#{avulsa.id}?#{%{set_id: set.id}}"
    assert has_element?(view, "#dj-deck-b a[href='#{path}'][target='_blank']")
    assert has_element?(view, "#dj-library-track-#{avulsa.id} a[href='#{path}'][target='_blank']")

    {:ok, ficha, _html} = live(conn, path)
    assert has_element?(ficha, "a[href='/set/#{set.id}']", "Voltar ao set · #{set.name}")
    assert has_element?(ficha, "a[href='/set/#{set.id}?track_id=#{avulsa.id}']", "Usar neste set")
    assert has_element?(view, "#dj-deck-b [data-version-path]", avulsa.rel_path)

    render_change(view, "select_set", %{"set_id" => ""})
    assert has_element?(view, "#dj-deck-b a[href='/track/#{avulsa.id}'][target='_blank']")

    assert has_element?(
             view,
             "#dj-library-track-#{avulsa.id} a[href='/track/#{avulsa.id}'][target='_blank']"
           )
  end

  test "queue status and position follow track identity after a live reorder and stop", %{
    conn: conn
  } do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Três", 108.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id})

    assert has_element?(
             view,
             "#dj-queue-track-#{a.id} [data-queue-state=current]",
             "Atual do set"
           )

    assert has_element?(view, "#dj-queue-track-#{b.id} [data-queue-state=next]", "Próxima")

    :ok = Sets.move(set, c, :up)

    assert has_element?(
             view,
             "#dj-queue-track-#{c.id}[data-position='2'] [data-queue-state=next]",
             "Próxima"
           )

    assert has_element?(view, "#dj-queue-track-#{b.id}[data-position='3']")
    refute has_element?(view, "#dj-queue-track-#{b.id} [data-queue-state=next]")
    assert has_element?(view, "#dj-next-card", "Três")
    assert has_element?(view, "#dj-next-card", "Fila #2")

    render_click(view, "stop_all", %{})
    refute has_element?(view, "#dj-queue-list [data-queue-state=current]")
    refute has_element?(view, "#dj-queue-list [data-queue-state=next]")
  end

  test "an empty selected queue and playback outside the set do not claim the last track is playing",
       %{conn: conn} do
    {:ok, empty} = Sets.create("Vazio")
    view = open_console(conn, empty)
    assert has_element?(view, "button[phx-click=play_set][disabled]")
    assert has_element?(view, "#dj-queue-panel", "Este set não tem faixas.")

    {set, [_]} = set_with_tracks([{"Única", 120.0}])
    render_change(view, "select_set", %{"set_id" => set.id})
    track = insert(:track, status: :present, tag_title: "Avulsa", duration_ms: 90_000)
    render_hook(view, "deck_started", %{"deck" => "a", "track_id" => track.id})
    assert has_element?(view, "#dj-next-empty", "Faixa fora do set — sem próxima armada")
    refute has_element?(view, "#dj-next-empty", "Última faixa do set")
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

  test "playing reconnect preserves an actual manual preload and never sends the superseded plan first",
       %{conn: conn} do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Três", 106.0}])
    manual = insert(:track, status: :present, tag_title: "Escolha do DJ", duration_ms: 90_000)
    {:ok, _} = Sets.set_breather(set, b, true)

    payload = %{
      "decks" => %{"a" => a.id, "b" => manual.id},
      "deck" => "a",
      "playing_track_id" => a.id,
      "set_id" => set.id,
      "auto" => true,
      "has_hint" => true,
      "manual_hint" => %{
        "deck" => "b",
        "track_id" => manual.id,
        "planned_track_id" => b.id,
        "source_track_id" => a.id,
        "set_id" => set.id
      }
    }

    {:ok, view, _} = live(conn, ~p"/discotecagem?set=#{set.id}")
    render_hook(view, "console_resync", payload)
    manual_id = manual.id

    assert_push_event(view, "dj_hint", %{
      track: %{id: ^manual_id},
      transition: %{"breather" => true, "to_ms" => nil}
    })

    refute_push_event(view, "dj_hint", %{})
    assert Playback.now_playing() == %{track_id: a.id, set_id: set.id}
    assert Playback.quiet_mode_active?()
    refute_push_event(view, "dj_load", %{autoplay: true})

    :ok = Sets.move(set, c, :up)
    {:ok, remounted, _} = live(conn, ~p"/discotecagem?set=#{set.id}")
    render_hook(remounted, "console_resync", payload)
    cid = c.id
    assert_push_event(remounted, "dj_hint", %{track: %{id: ^cid}})
    refute_push_event(remounted, "dj_hint", %{})
  end

  test "removing the only successor never arms the playing track as its own next track", %{
    conn: conn
  } do
    {set, [_a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Tres", 108.0}])
    view = open_console(conn, set)
    render_hook(view, "deck_started", %{"deck" => "b", "track_id" => b.id})
    assert_push_event(view, "dj_hint", %{track: %{title: "Tres"}})
    :ok = Sets.remove(set, c)
    assert_push_event(view, "dj_hint_clear", %{})
  end

  test "removing the playing opener keeps the live successor through another set edit", %{
    conn: conn
  } do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Tres", 108.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_hint", %{track: %{title: "Dois"}})
    :ok = Sets.remove(set, a)
    assert render(view) =~ "Dois"
    refute_push_event(view, "dj_hint_clear", %{})
    :ok = Sets.remove(set, b)
    assert_push_event(view, "dj_hint", %{track: %{id: id}, transition: %{"from_ms" => 150_000}})
    assert id == c.id
  end

  test "manual library playback releases the old set hint across later queue edits", %{conn: conn} do
    {set, [_a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_hint", %{track: %{title: "Dois"}})
    lib = insert(:track, status: :present, tag_title: "Avulsa")
    render_hook(view, "deck_started", %{"deck" => "b", "track_id" => lib.id})
    assert_push_event(view, "dj_hint_clear", %{})
    Sets.move(set, b, :top)
    render(view)
    refute_push_event(view, "dj_hint", %{})
  end

  test "a paused set follows the saved order and rejects acknowledgements for a superseded version",
       %{conn: conn} do
    {set, [a, b, c]} = set_with_tracks([{"Baião", 100.0}, {"Baião", 101.0}, {"Baião", 102.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    bid = b.id
    cid = c.id
    assert_push_event(view, "dj_hint", %{track: %{id: ^bid}})
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => b.id})
    render_hook(view, "console_idle", %{})
    :ok = Sets.move(set, c, :up)
    render(view)
    assert_push_event(view, "dj_hint", %{track: %{id: ^cid}, position: 2})
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => c.id})
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => b.id})
    assert has_element?(view, "section:has(#dj-play-b) a[href^='/track/#{c.id}']")
    refute Playback.quiet_mode_active?()

    {:ok, other} = Sets.create_filled("Bis", [a, b])
    render_change(view, "select_set", %{"set_id" => other.id})
    assert_patch(view, ~p"/discotecagem?set=#{other.id}")
    assert_push_event(view, "dj_hint", %{track: %{id: ^bid}})
    render_change(view, "select_set", %{"set_id" => ""})
    assert_patch(view, ~p"/discotecagem")
    assert_push_event(view, "dj_hint_clear", %{})
  end

  test "changing the selected set updates only the console's own now-playing association", %{
    conn: conn
  } do
    {set, [a, b]} = set_with_tracks([{"A", 100.0}, {"B", 101.0}])
    {:ok, other} = Sets.create_filled("Bis", [b, a])
    {:ok, empty} = Sets.create("Vazio")
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    render_change(view, "select_set", %{"set_id" => other.id})
    assert Playback.now_playing() == %{track_id: a.id, set_id: other.id}
    render_change(view, "select_set", %{"set_id" => empty.id})
    assert Playback.now_playing() == %{track_id: a.id, set_id: nil}

    Playback.set_now_playing(%{track_id: a.id, set_id: set.id})
    render_hook(view, "console_idle", %{})
    render_change(view, "select_set", %{"set_id" => other.id})
    assert Playback.now_playing() == %{track_id: a.id, set_id: set.id}
  end

  test "reconnect while paused restores the next version without announcing playback", %{
    conn: conn
  } do
    {set, [a, b, c]} = set_with_tracks([{"A", 100.0}, {"B", 101.0}, {"B", 101.0}])
    :ok = Sets.move(set, c, :up)
    {:ok, view, _} = live(conn, ~p"/discotecagem?set=#{set.id}")

    render_hook(view, "console_resync", %{
      "decks" => %{"a" => a.id, "b" => b.id},
      "paused_deck" => "a",
      "set_id" => set.id,
      "auto" => true
    })

    cid = c.id
    assert_push_event(view, "dj_hint", %{track: %{id: ^cid}})
    refute Playback.quiet_mode_active?()
    refute_push_event(view, "dj_load", %{autoplay: true})
    render_hook(view, "deck_loaded", %{"deck" => "a", "track_id" => b.id})
    assert_push_event(view, "dj_hint_clear", %{})
    :ok = Sets.move(set, b, :top)
    render(view)
    refute_push_event(view, "dj_hint", %{})
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

  test "saved marker edits reach a loaded deck without loading its audio again", %{conn: conn} do
    {set, [track]} = set_with_tracks([{"Um", 120.0}])
    view = open_console(conn, set)
    id = track.id
    render_hook(view, "deck_loaded", %{"deck" => "b", "track_id" => id})

    {:ok, updated} = Tracks.add_marker(track, 3500, "Entrada")
    Playback.broadcast_markers_changed(id)
    expected = updated.cue_points
    assert_push_event(view, "dj_markers", %{track_id: ^id, markers: ^expected})

    {:ok, updated} = Tracks.remove_marker(updated, 3500)
    Playback.broadcast_markers_changed(id)
    expected = updated.cue_points
    assert_push_event(view, "dj_markers", %{track_id: ^id, markers: ^expected})
    refute_push_event(view, "dj_load", %{})
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

  test "console_resync restores the labels of two manually loaded, paused decks", %{conn: conn} do
    {set, [a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)

    render_hook(view, "console_resync", %{"decks" => %{"a" => a.id, "b" => b.id}, "auto" => false})

    for track <- [a, b] do
      assert_push_event(view, "dj_markers", %{track_id: id, markers: markers})
      assert {id, markers} == {track.id, track.cue_points}
    end

    for {deck, track} <- [{"a", a}, {"b", b}] do
      assert has_element?(
               view,
               "section:has(button[phx-click=eject_deck][phx-value-deck=#{deck}]) a[href='/track/#{track.id}?set_id=#{set.id}']"
             )
    end
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

  test "skipping a broken preload uses the outro of the track that is actually playing", %{
    conn: conn
  } do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Tres", 108.0}])

    b
    |> Ecto.Changeset.change(
      cue_points: [%{"ms" => 185_000, "type" => "outro", "source" => "auto"}]
    )
    |> Beatgrid.Repo.update!()

    view = open_console(conn, set)
    render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id})
    assert_push_event(view, "dj_hint", %{track: %{title: "Dois"}})
    render_hook(view, "deck_error", %{"deck" => "b", "track_id" => b.id})
    assert_push_event(view, "dj_hint", %{track: %{id: id}, transition: %{"from_ms" => 150_000}})
    assert id == c.id
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

  test "LOAD asks the console before replacing a record on the logical set deck", %{conn: conn} do
    {set, [first, second, third]} =
      set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Três", 110.0}])

    {:ok, _} = Sets.set_breather(set, second, true)
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_load", %{deck: "a", autoplay: true})
    assert_push_event(view, "dj_hint", %{transition: %{"breather" => true}})

    id = third.id

    view
    |> element(
      "#dj-queue-list button[phx-click=load_deck][phx-value-deck=a][phx-value-track_id='#{id}']"
    )
    |> render_click()

    assert_push_event(view, "dj_load", %{deck: "a", track: %{id: ^id}, autoplay: false})

    assert has_element?(
             view,
             "section:has(button[phx-click=eject_deck][phx-value-deck=a]) a[href='/track/#{first.id}?set_id=#{set.id}']"
           )

    render_hook(view, "deck_loaded", %{"deck" => "a", "track_id" => id})

    assert has_element?(
             view,
             "section:has(button[phx-click=eject_deck][phx-value-deck=a]) a[href='/track/#{id}?set_id=#{set.id}']"
           )

    render_hook(view, "deck_error", %{"deck" => "a", "track_id" => id})
    refute_push_event(view, "dj_load", %{autoplay: true})
    refute_push_event(view, "dj_hint_clear", %{})
    assert Playback.now_playing() == %{track_id: first.id, set_id: set.id}
  end

  test "resync during a breather keeps the prepared deck and the original set pointer", %{
    conn: conn
  } do
    {set, [first, second, third]} =
      set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Três", 110.0}])

    {:ok, view, _} = live(conn, ~p"/discotecagem")

    render_hook(view, "console_resync", %{
      "deck" => "a",
      "playing_track_id" => first.id,
      "set_id" => set.id,
      "auto" => true,
      "decks" => %{"a" => third.id, "b" => second.id}
    })

    assert has_element?(
             view,
             "section:has(button[phx-click=eject_deck][phx-value-deck=a]) a[href='/track/#{third.id}?set_id=#{set.id}']"
           )

    assert Playback.now_playing() == %{track_id: first.id, set_id: set.id}
    :ok = Sets.remove(set, second)
    id = third.id
    assert_push_event(view, "dj_hint", %{track: %{id: ^id}})
  end

  test "a requested LOAD changes the deck header only when the console accepts it", %{conn: conn} do
    {set, [_, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "load_deck", %{"deck" => "b", "track_id" => b.id})
    assert_push_event(view, "dj_load", %{deck: "b", autoplay: false})
    eject = "button[phx-click=eject_deck][phx-value-deck=b]"
    refute has_element?(view, eject)
    render_hook(view, "deck_loaded", %{"deck" => "b", "track_id" => b.id})
    assert has_element?(view, eject)
    render_click(view, "eject_deck", %{"deck" => "b"})
    assert has_element?(view, eject)
    render_hook(view, "deck_ejected", %{"deck" => "b"})
    refute has_element?(view, eject)
  end

  test "resuming a paused deck preserves a manual preload for the same planned successor", %{
    conn: conn
  } do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Três", 106.0}])
    manual = insert(:track, status: :present, tag_title: "Escolha do DJ", duration_ms: 90_000)
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    bid = b.id
    manual_id = manual.id
    assert_push_event(view, "dj_hint", %{track: %{id: ^bid}})
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => b.id})
    render_hook(view, "console_idle", %{})

    render_hook(view, "deck_loaded", %{
      "deck" => "b",
      "track_id" => manual.id,
      "replaced_hint_id" => b.id
    })

    render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id})
    refute_push_event(view, "dj_hint", %{})
    assert has_element?(view, "div:has(> div #dj-countdown) > p", "Escolha do DJ")
    render_hook(view, "console_idle", %{})

    # Updating transition intent for the same boundary must not undo the DJ's load.
    {:ok, _} = Sets.set_breather(set, b, true)

    assert_push_event(view, "dj_hint", %{
      track: %{id: ^manual_id},
      transition: %{"breather" => true, "to_ms" => nil}
    })

    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => manual.id})
    render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id})
    refute_push_event(view, "dj_hint", %{})
    assert has_element?(view, "div:has(> div #dj-countdown) > p", "Escolha do DJ")

    # A changed successor wins over the manual override, even if the source is paused.
    render_hook(view, "console_idle", %{})
    :ok = Sets.move(set, c, :up)
    cid = c.id
    assert_push_event(view, "dj_hint", %{track: %{id: ^cid}})
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => c.id})
    render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id})
    refute_push_event(view, "dj_hint", %{})
    assert has_element?(view, "div:has(> div #dj-countdown) > p", "Três")
  end

  test "paused reconnect preserves an acknowledged manual override only for the unchanged boundary",
       %{conn: conn} do
    {set, [a, b, c]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}, {"Três", 106.0}])
    manual = insert(:track, status: :present, tag_title: "Escolha do DJ", duration_ms: 90_000)
    {:ok, _} = Sets.set_breather(set, b, true)

    payload = %{
      "decks" => %{"a" => a.id, "b" => manual.id},
      "paused_deck" => "a",
      "set_id" => set.id,
      "auto" => true,
      "has_hint" => true,
      "manual_hint" => %{
        "deck" => "b",
        "track_id" => manual.id,
        "planned_track_id" => b.id,
        "source_track_id" => a.id,
        "set_id" => set.id
      }
    }

    {:ok, view, _} = live(conn, ~p"/discotecagem?set=#{set.id}")
    render_hook(view, "console_resync", payload)
    manual_id = manual.id

    assert_push_event(view, "dj_hint", %{
      track: %{id: ^manual_id},
      transition: %{"breather" => true, "to_ms" => nil}
    })

    refute Playback.quiet_mode_active?()
    refute_push_event(view, "dj_load", %{autoplay: true})

    # If the order changed while disconnected, that same remembered override loses.
    :ok = Sets.move(set, c, :up)
    {:ok, remounted, _} = live(conn, ~p"/discotecagem?set=#{set.id}")
    render_hook(remounted, "console_resync", payload)
    cid = c.id
    assert_push_event(remounted, "dj_hint", %{track: %{id: ^cid}})
    refute_push_event(remounted, "dj_load", %{autoplay: true})
  end

  test "removing the only successor while the source is paused clears a manual override", %{
    conn: conn
  } do
    {set, [a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    manual = insert(:track, status: :present, tag_title: "Escolha do DJ")
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_hint", %{})
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => b.id})
    render_hook(view, "console_idle", %{})

    render_hook(view, "deck_loaded", %{
      "deck" => "b",
      "track_id" => manual.id,
      "replaced_hint_id" => b.id
    })

    :ok = Sets.remove(set, b)
    assert_push_event(view, "dj_hint_clear", %{})
    render_hook(view, "deck_started", %{"deck" => "a", "track_id" => a.id})
    refute_push_event(view, "dj_hint", %{})
    assert render(view) =~ "Última faixa do set"
  end

  test "a media error on the paused source never starts the next deck", %{conn: conn} do
    {set, [a, _b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_load", %{autoplay: true})
    assert_push_event(view, "dj_hint", %{})
    render_hook(view, "console_idle", %{})
    render_hook(view, "deck_error", %{"deck" => "a", "track_id" => a.id, "was_playing" => false})
    refute_push_event(view, "dj_load", %{autoplay: true})
    assert_push_event(view, "dj_hint_clear", %{})
    refute Playback.quiet_mode_active?()
  end

  test "a live media error still advances if the idle notification arrived first", %{conn: conn} do
    {set, [a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    assert_push_event(view, "dj_load", %{autoplay: true})
    render_hook(view, "console_idle", %{})
    render_hook(view, "deck_error", %{"deck" => "a", "track_id" => a.id, "was_playing" => true})
    bid = b.id
    assert_push_event(view, "dj_load", %{autoplay: true, deck: "b", track: %{id: ^bid}})
  end

  test "the next card follows a manual replacement on the armed deck", %{conn: conn} do
    {set, [_a, b]} = set_with_tracks([{"Um", 100.0}, {"Dois", 104.0}])
    track = insert(:track, status: :present, tag_title: "Avulsa", duration_ms: 90_000)
    view = open_console(conn, set)
    render_click(view, "play_set", %{})
    render_hook(view, "hint_armed", %{"deck" => "b", "track_id" => b.id})

    render_hook(view, "deck_loaded", %{
      "deck" => "b",
      "track_id" => track.id,
      "replaced_hint_id" => b.id
    })

    assert has_element?(view, "div:has(> div #dj-countdown) > p", "Avulsa")
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
