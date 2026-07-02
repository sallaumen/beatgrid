defmodule BeatgridWeb.DiscotecagemLive do
  @moduledoc """
  A mesa de discotecagem: dois decks visíveis (inspirados na Numark DJ2GO2 Touch),
  mixer central com crossfader e eco, e reprodução automática de um set com as
  transições acontecendo NA TELA — para estudar e para dançar.

  Divisão de autoridade (regras do post-mortem da mesa antiga, ver
  docs/superpowers/specs/2026-07-02-discotecagem-design.md):

    * O SERVIDOR é o dono da ordem do set. Ele mantém o ponteiro (faixa atual) e
      empurra ao cliente apenas uma *dica revogável* da próxima entrada
      (`dj_hint`, via `Sets.entry_after/2` com leitura fresca). Edições no set
      chegam por `{:set_changed, id}` e substituem a dica antes da transição.
    * O CLIENTE (hook `.DjConsole` + `assets/js/dj/engine.js`) é o dono do áudio:
      dois `<audio>` fixos, ganho SÓ por automação WebAudio, transição disparada
      no deck ocioso com gate de `canplay`. Ele reporta `transition_started` /
      `track_ended` / `deck_error` e o servidor adota a realidade sonora.
    * Um único avanço por fronteira de faixa (token no engine + dica trocada a
      cada avanço) — nunca os dois lados avançando ao mesmo tempo.

  A controladora MIDI entra pelo hook `.DjMidi` (Web MIDI), que traduz mensagens
  cruas em ações semânticas (`assets/js/dj/midi_map.js`) e as despacha ao console
  por eventos de janela — a mesa na tela espelha cada gesto físico.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Playback
  alias Beatgrid.Sets

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Discotecagem",
       sets: Sets.list(),
       set: nil,
       entries: [],
       subscribed: MapSet.new(),
       deck_a: nil,
       deck_b: nil,
       active_deck: nil,
       playing?: false,
       auto?: true,
       pointer_id: nil,
       hint: nil,
       midi: %{connected: false, name: nil}
     )}
  end

  # ── seleção e partida ────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_set", %{"set_id" => ""}, socket),
    do: {:noreply, assign(socket, set: nil, entries: [])}

  def handle_event("select_set", %{"set_id" => id}, socket) do
    case Sets.get(id) do
      nil ->
        {:noreply, socket}

      set ->
        {:noreply,
         socket
         |> subscribe_once(set.id)
         |> assign(set: set, entries: Sets.entries(set))}
    end
  end

  def handle_event("play_set", _params, %{assigns: %{set: %{} = set}} = socket) do
    case Sets.entries(set) do
      [] ->
        {:noreply, put_flash(socket, :error, "Este set está vazio.")}

      [first | _] = entries ->
        Playback.set_now_playing(%{track_id: first.track.id, set_id: set.id})
        Playback.activate_quiet_mode()

        {:noreply,
         socket
         |> assign(
           entries: entries,
           deck_a: first.track,
           active_deck: "a",
           playing?: true,
           pointer_id: first.track.id
         )
         |> push_event("dj_stop", %{})
         |> push_event("dj_auto", %{on: socket.assigns.auto?})
         |> push_event("dj_load", %{
           deck: "a",
           track: track_payload(first.track),
           autoplay: true,
           at_ms: 0
         })
         |> push_hint(Sets.entry_after(set.id, first.track.id))}
    end
  end

  def handle_event("play_set", _params, socket), do: {:noreply, socket}

  def handle_event("load_deck", %{"deck" => deck, "track_id" => id}, socket)
      when deck in ["a", "b"] do
    cond do
      socket.assigns.playing? and socket.assigns.active_deck == deck ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Deck #{String.upcase(deck)} está no ar — carregue no outro deck."
         )}

      track = Tracks.get_with_song(id) ->
        {:noreply,
         socket
         |> assign_deck(deck, track)
         |> push_event("dj_load", %{
           deck: deck,
           track: track_payload(track),
           autoplay: false,
           at_ms: 0
         })}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_auto", _params, socket) do
    auto = not socket.assigns.auto?
    {:noreply, socket |> assign(auto?: auto) |> push_event("dj_auto", %{on: auto})}
  end

  def handle_event("stop_all", _params, socket) do
    Playback.clear_now_playing()
    Playback.deactivate_quiet_mode()

    {:noreply,
     socket
     |> assign(playing?: false, active_deck: nil, hint: nil)
     |> push_event("dj_stop", %{})}
  end

  # ── protocolo do console (o cliente reporta, o servidor adota a realidade) ──

  def handle_event("deck_started", %{"deck" => deck, "track_id" => id}, socket) do
    socket =
      socket
      |> assign(active_deck: deck, playing?: true)
      |> assign_deck_by_id(deck, id)

    case in_set_entry(socket, id) do
      nil ->
        Playback.set_now_playing(%{track_id: id, set_id: nil})
        {:noreply, socket}

      _entry ->
        set = socket.assigns.set
        Playback.set_now_playing(%{track_id: id, set_id: set.id})
        Playback.activate_quiet_mode()

        {:noreply,
         socket
         |> assign(pointer_id: id)
         |> push_hint(Sets.entry_after(set.id, id))}
    end
  end

  def handle_event("transition_started", %{"to_track_id" => to_id, "deck" => deck}, socket) do
    socket =
      socket
      |> assign(active_deck: deck, playing?: true, pointer_id: to_id)
      |> assign_deck_by_id(deck, to_id)

    case socket.assigns.set do
      nil ->
        Playback.set_now_playing(%{track_id: to_id, set_id: nil})
        {:noreply, socket}

      set ->
        Playback.set_now_playing(%{track_id: to_id, set_id: set.id})
        Playback.activate_quiet_mode()
        {:noreply, push_hint(socket, Sets.entry_after(set.id, to_id))}
    end
  end

  # O cliente armou a dica num deck concreto — refletimos no cabeçalho do deck.
  def handle_event("hint_armed", %{"deck" => deck, "track_id" => id}, socket),
    do: {:noreply, assign_deck_by_id(socket, deck, id)}

  def handle_event("track_ended", %{"track_id" => id}, socket) do
    Playback.set_now_playing(%{track_id: id, set_id: nil})
    Playback.deactivate_quiet_mode()
    {:noreply, assign(socket, playing?: false, active_deck: nil, hint: nil)}
  end

  # Erro de mídia: a faixa é PULADA, nunca derruba o som (regra nunca-mais).
  def handle_event("deck_error", %{"deck" => deck, "track_id" => id}, socket) do
    set = socket.assigns.set
    next = set && Sets.entry_after(set.id, id)
    socket = put_flash(socket, :error, "Erro ao tocar uma faixa — pulada.")

    cond do
      is_nil(set) ->
        {:noreply, socket}

      deck == socket.assigns.active_deck and not is_nil(next) ->
        {:noreply,
         push_event(socket, "dj_load", %{
           deck: other_deck(deck),
           track: track_payload(next.track),
           autoplay: true,
           at_ms: transition_to_ms(next.transition)
         })}

      deck == socket.assigns.active_deck ->
        {:noreply, assign(socket, playing?: false, active_deck: nil, hint: nil)}

      true ->
        {:noreply, push_hint(socket, next)}
    end
  end

  # Reconexão de socket: adotamos o que o cliente ainda está tocando.
  def handle_event("console_resync", %{"playing_track_id" => id, "deck" => deck}, socket)
      when is_binary(id) and is_binary(deck),
      do: handle_event("deck_started", %{"deck" => deck, "track_id" => id}, socket)

  def handle_event("console_resync", _params, socket), do: {:noreply, socket}

  def handle_event("midi_status", params, socket) do
    {:noreply,
     assign(socket, midi: %{connected: params["connected"] == true, name: params["name"]})}
  end

  # Edição estrutural do set ao vivo: recarrega a fila e troca a dica armada
  # ANTES da transição disparar — a raiz do bug da festa, agora coberta.
  @impl true
  def handle_info({:set_changed, set_id}, %{assigns: %{set: %{id: set_id} = set}} = socket) do
    socket = assign(socket, entries: Sets.entries(set))

    if socket.assigns.playing? && socket.assigns.pointer_id do
      {:noreply, push_hint(socket, Sets.entry_after(set_id, socket.assigns.pointer_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Saiu da página com a mesa no ar: o áudio morre junto (elementos locais),
  # então zera o ponteiro global. Se a mesa estava parada, o player global pode
  # estar tocando — não tocamos no ponteiro dele.
  @impl true
  def terminate(_reason, %{assigns: %{playing?: true}}) do
    Playback.reset_now_playing()
    Playback.deactivate_quiet_mode()
  end

  def terminate(_reason, _socket), do: :ok

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp subscribe_once(socket, set_id) do
    if MapSet.member?(socket.assigns.subscribed, set_id) do
      socket
    else
      if connected?(socket), do: Sets.subscribe_set(set_id)
      assign(socket, subscribed: MapSet.put(socket.assigns.subscribed, set_id))
    end
  end

  defp in_set_entry(%{assigns: %{set: nil}}, _id), do: nil

  defp in_set_entry(%{assigns: %{entries: entries}}, id),
    do: Enum.find(entries, &(&1.track.id == id))

  defp assign_deck(socket, "a", track), do: assign(socket, deck_a: track)
  defp assign_deck(socket, "b", track), do: assign(socket, deck_b: track)

  defp assign_deck_by_id(socket, deck, id) do
    current = if deck == "a", do: socket.assigns.deck_a, else: socket.assigns.deck_b

    cond do
      current && current.id == id -> socket
      track = Tracks.get_with_song(id) -> assign_deck(socket, deck, track)
      true -> socket
    end
  end

  defp other_deck("a"), do: "b"
  defp other_deck("b"), do: "a"

  defp transition_to_ms(%{"to_ms" => ms}) when is_integer(ms) and ms > 0, do: ms
  defp transition_to_ms(_transition), do: 0

  defp track_payload(track) do
    %{
      id: track.id,
      src: ~p"/audio/#{track.id}",
      title: track.tag_title || track.filename,
      artist: track.tag_artist,
      bpm: Library.effective(track).bpm,
      duration_ms: track.duration_ms,
      markers: track.cue_points || []
    }
  end

  # Empurra a dica ao console, deduplicada: rearmar a mesma dica recarregaria o
  # preload do deck ocioso à toa. `nil` limpa (fim do set / entrada removida).
  defp push_hint(socket, nil) do
    if socket.assigns.hint == nil do
      socket
    else
      socket |> assign(hint: nil) |> push_event("dj_hint_clear", %{})
    end
  end

  defp push_hint(socket, hint) do
    if same_hint?(socket.assigns.hint, hint) do
      socket
    else
      socket
      |> assign(hint: hint)
      |> push_event("dj_hint", %{
        track: track_payload(hint.track),
        transition: hint.transition,
        position: hint.position
      })
    end
  end

  defp same_hint?(%{track: %{id: id}, transition: t}, %{track: %{id: id}, transition: t}),
    do: true

  defp same_hint?(_current, _new), do: false

  defp t_label(nil), do: "SEQ"
  defp t_label("cut"), do: "CORTE"
  defp t_label("fade"), do: "FADE"
  defp t_label("crossfade"), do: "XFADE"
  defp t_label("echo"), do: "ECO"
  defp t_label(_type), do: "SEQ"

  defp bpm_text(bpm) when is_number(bpm), do: bpm |> round() |> Integer.to_string()
  defp bpm_text(_bpm), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:discotecagem} socket={@socket}>
      <div class="mx-auto max-w-6xl px-6 py-6">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-[22px] font-semibold tracking-tight">Discotecagem</h1>
            <p class="mt-0.5 text-[12px] text-ink-muted">
              Dois decks, transições visíveis — na tela e na controladora.
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <form id="dj-set-picker" phx-change="select_set">
              <select
                name="set_id"
                class="h-9 rounded-lg border border-white/10 bg-input px-3 text-[12px] text-ink focus:border-primary/60 focus:outline-none"
              >
                <option value="">Escolher set…</option>
                <option :for={s <- @sets} value={s.id} selected={@set && @set.id == s.id}>
                  {s.name}
                </option>
              </select>
            </form>
            <button
              :if={@set}
              type="button"
              phx-click="play_set"
              class="flex h-9 items-center gap-1.5 rounded-lg bg-primary/15 px-3 text-[12px] font-semibold text-primary hover:bg-primary/25"
            >
              ▶ Tocar set
            </button>
            <button
              type="button"
              phx-click="toggle_auto"
              title="Com AUTO ligado, o console dispara as transições sozinho na janela marcada."
              class={[
                "flex h-9 items-center gap-1.5 rounded-lg border px-3 text-[11px] font-bold uppercase tracking-wider",
                @auto? && "border-amber/50 bg-amber/15 text-amber",
                !@auto? && "border-white/10 bg-input text-ink-faint hover:text-ink"
              ]}
            >
              <span class={["size-1.5 rounded-full", (@auto? && "bg-amber") || "bg-white/20"]}></span>
              Auto
            </button>
            <button
              type="button"
              phx-click="stop_all"
              class="flex h-9 items-center rounded-lg border border-coral/30 bg-coral/10 px-3 text-[11px] font-bold uppercase tracking-wider text-coral hover:bg-coral/20"
            >
              Stop
            </button>
          </div>
        </div>

        <div id="dj-console" phx-hook=".DjConsole" class="mt-5">
          <div class="grid gap-4 lg:grid-cols-[1fr_236px_1fr]">
            <.deck_panel
              d="a"
              track={@deck_a}
              active={@playing? and @active_deck == "a"}
              accent="#8b7bf0"
            />
            <.mixer hint={@hint} playing={@playing?} />
            <.deck_panel
              d="b"
              track={@deck_b}
              active={@playing? and @active_deck == "b"}
              accent="#2d9cff"
            />
          </div>
          <div id="dj-audio-rack" phx-update="ignore">
            <audio id="dj-audio-a" preload="auto" class="hidden"></audio>
            <audio id="dj-audio-b" preload="auto" class="hidden"></audio>
          </div>
        </div>

        <div class="mt-4 grid items-start gap-4 lg:grid-cols-[1fr_300px]">
          <.set_rail set={@set} entries={@entries} pointer_id={@pointer_id} hint={@hint} />
          <div class="flex flex-col gap-4">
            <.midi_panel midi={@midi} />
            <section class="rounded-2xl border border-white/8 bg-surface p-4">
              <h2 class="text-[11px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
                Eventos da mesa
              </h2>
              <div
                id="dj-log"
                phx-update="ignore"
                class="mt-2 flex max-h-44 flex-col gap-0.5 overflow-auto font-mono text-[10px] leading-relaxed text-ink-muted"
              >
                <p class="text-ink-faint">— mesa pronta —</p>
              </div>
            </section>
          </div>
        </div>
      </div>

      <style>
        #dj-echo-light[data-on="true"] {
          background: #ffb020;
          box-shadow: 0 0 12px #ffb020, 0 0 3px #ffb020;
        }
      </style>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DjConsole">
        import {createEngine} from "@/js/dj/engine.js"

        const ACCENTS = {a: "#8b7bf0", b: "#2d9cff"}
        const byId = (id) => document.getElementById(id)
        const fmt = (ms) => {
          if (ms == null || !isFinite(ms)) return "0:00"
          const t = Math.max(Math.floor(ms / 1000), 0)
          return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`
        }

        export default {
          mounted() {
            this.tracks = {a: null, b: null}
            this.hint = null
            this.pendingHint = null
            this.cursor = -1

            this.engine = createEngine({
              deckElA: byId("dj-audio-a"),
              deckElB: byId("dj-audio-b"),
              callbacks: {
                deckStarted: ({deck, trackId}) => {
                  this.pushEvent("deck_started", {deck, track_id: trackId})
                  window.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "dj-console"}}))
                },
                transitionStarted: ({fromTrackId, toTrackId, type, deck}) => {
                  this.hint = null
                  this.pushEvent("transition_started", {
                    from_track_id: fromTrackId, to_track_id: toTrackId, type, deck,
                  })
                  this.log(`transição ${type.toUpperCase()} → deck ${deck.toUpperCase()}`)
                  window.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "dj-console"}}))
                },
                trackEnded: ({trackId}) => {
                  this.hint = null
                  this.pushEvent("track_ended", {track_id: trackId})
                  this.log("fim do set")
                },
                deckError: ({deck, trackId}) => {
                  this.pushEvent("deck_error", {deck, track_id: trackId})
                  this.log(`⚠ erro no deck ${deck.toUpperCase()} — pulando a faixa`)
                },
                xfadePos: ({pos}) => {
                  const x = byId("dj-xfader")
                  if (x && document.activeElement !== x) x.value = Math.round(pos * 100)
                },
                echoState: ({on, delayMs}) => {
                  const light = byId("dj-echo-light")
                  if (light) light.dataset.on = on ? "true" : "false"
                  if (on) this.log(`eco ligado — delay ${delayMs}ms`)
                },
                // Um deck acabou de silenciar: é a hora de armar a dica que estava
                // esperando (dirigido a evento — funciona com a aba em segundo plano).
                deckFreed: () => {
                  if (this.pendingHint) this.armHint(this.pendingHint)
                },
              },
            })

            this.handleEvent("dj_load", ({deck, track, autoplay, at_ms}) => {
              if (!this.engine.loadDeck(deck, track, {autoplay, atMs: at_ms || 0})) {
                this.log(`deck ${deck.toUpperCase()} está no ar — carga recusada`)
                return
              }
              this.tracks[deck] = track
              this.renderDeckStatics(deck, track)
              this.log(`deck ${deck.toUpperCase()} ← ${track.title}`)
            })
            this.handleEvent("dj_hint", (hint) => this.armHint(hint))
            this.handleEvent("dj_hint_clear", () => {
              this.hint = null
              this.pendingHint = null
              this.engine.clearHint()
            })
            this.handleEvent("dj_auto", ({on}) => {
              this.engine.setAuto(on)
              this.log(on ? "AUTO ligado" : "AUTO desligado")
            })
            this.handleEvent("dj_stop", () => {
              this.engine.stopAll()
              this.hint = null
              this.pendingHint = null
            })

            for (const d of ["a", "b"]) {
              byId(`dj-play-${d}`).addEventListener("click", () => this.engine.playPause(d))
              byId(`dj-cue-${d}`).addEventListener("click", () => this.cue(d))
              byId(`dj-sync-${d}`).addEventListener("click", () => {
                if (this.engine.sync(d)) this.log(`SYNC no deck ${d.toUpperCase()}`)
                else this.log("SYNC indisponível (falta BPM em um dos decks)")
              })
              byId(`dj-strip-${d}`).addEventListener("click", (e) => {
                const track = this.tracks[d]
                if (!track || !track.duration_ms) return
                const rect = e.currentTarget.getBoundingClientRect()
                this.engine.cueTo(d, ((e.clientX - rect.left) / rect.width) * track.duration_ms)
              })
              byId(`dj-pitch-${d}`).addEventListener("input", (e) =>
                this.applyPitch(d, Number(e.target.value) / 100)
              )
              byId(`dj-level-${d}`).addEventListener("input", (e) =>
                this.engine.setDeckLevel(d, Number(e.target.value) / 100)
              )
              for (let n = 1; n <= 4; n++) {
                byId(`dj-pad-${d}-${n}`).addEventListener("click", (e) => {
                  const ms = e.currentTarget.dataset.ms
                  if (ms != null && ms !== "") this.engine.cueTo(d, Number(ms))
                })
              }
            }
            byId("dj-xfader").addEventListener("input", (e) =>
              this.engine.setCrossfader(Number(e.target.value) / 100)
            )

            this.onMidi = (e) => this.applyMidi(e.detail)
            window.addEventListener("dj:midi", this.onMidi)

            // Exclusão mútua com o player global: uma única fonte audível.
            this.onForeignPlay = (e) => {
              if (e.detail.source !== "dj-console") this.engine.pauseAll()
            }
            window.addEventListener("beatgrid:playing", this.onForeignPlay)

            // Loop de pintura: SÓ espelha a UI — o áudio nunca depende dele.
            const tick = () => {
              this.raf = requestAnimationFrame(tick)
              const levels = this.engine.levels()
              this.setMeter("dj-meter-a", levels.a)
              this.setMeter("dj-meter-m", levels.master)
              this.setMeter("dj-meter-b", levels.b)
              this.paintDeck("a")
              this.paintDeck("b")
              this.paintCountdown()
              if (this.pendingHint) this.armHint(this.pendingHint)
            }
            this.raf = requestAnimationFrame(tick)
          },

          reconnected() {
            const snap = this.engine.snapshot()
            const deck = snap.a.playing ? "a" : snap.b.playing ? "b" : null
            this.pushEvent("console_resync", {
              deck,
              playing_track_id: deck ? snap[deck].trackId : null,
            })
          },

          destroyed() {
            cancelAnimationFrame(this.raf)
            window.removeEventListener("dj:midi", this.onMidi)
            window.removeEventListener("beatgrid:playing", this.onForeignPlay)
            this.engine.destroy()
          },

          log(msg) {
            const log = byId("dj-log")
            if (!log) return
            const at = new Date()
            const line = document.createElement("p")
            line.textContent =
              `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")} · ${msg}`
            log.prepend(line)
            while (log.children.length > 14) log.lastChild.remove()
          },

          armHint(hint) {
            const deck = this.engine.armHint(hint)
            if (deck === false) {
              // O deck ocioso ainda solta a cauda da transição anterior — o loop
              // de pintura tenta de novo até ele liberar.
              this.pendingHint = hint
              return
            }
            this.pendingHint = null
            this.hint = hint
            this.tracks[deck] = hint.track
            this.renderDeckStatics(deck, hint.track)
            this.pushEvent("hint_armed", {deck, track_id: hint.track.id})
            this.log(`próxima armada no deck ${deck.toUpperCase()}: ${hint.track.title}`)
          },

          renderDeckStatics(d, track) {
            const marks = byId(`dj-marks-${d}`)
            const dur = track.duration_ms || 0
            const COLORS = {cue: "#ffb020", intro: "#5ad1a0", outro: "#ff5d6c"}
            if (marks) {
              marks.innerHTML = ""
              ;(track.markers || []).forEach((m) => {
                if (!dur || m.ms < 0 || m.ms > dur) return
                const tick = document.createElement("div")
                tick.style.cssText =
                  `position:absolute;top:0;bottom:0;left:${(m.ms / dur) * 100}%;` +
                  `width:2px;background:${COLORS[m.type] || COLORS.cue}`
                marks.appendChild(tick)
              })
            }
            const pads = (track.markers || []).slice().sort((x, y) => x.ms - y.ms).slice(0, 4)
            for (let n = 1; n <= 4; n++) {
              const pad = byId(`dj-pad-${d}-${n}`)
              const lab = byId(`dj-padlab-${d}-${n}`)
              if (!pad || !lab) continue
              const m = pads[n - 1]
              if (m) {
                pad.disabled = false
                pad.dataset.ms = m.ms
                pad.style.borderColor = "#ffb02055"
                pad.style.color = "#ffb020"
                lab.textContent = m.label || fmt(m.ms)
              } else {
                pad.disabled = true
                delete pad.dataset.ms
                pad.style.borderColor = ""
                pad.style.color = ""
                lab.textContent = "—"
              }
            }
            const bpmEl = byId(`dj-jogbpm-${d}`)
            if (bpmEl) bpmEl.textContent = track.bpm ? `${Math.round(track.bpm)}` : ""
            const pitch = byId(`dj-pitch-${d}`)
            if (pitch) pitch.value = 50
            const plab = byId(`dj-pitchlab-${d}`)
            if (plab) plab.textContent = "0.0%"
          },

          cue(d) {
            const track = this.tracks[d]
            const first = ((track && track.markers) || [])
              .filter((m) => m.type === "cue" || m.type === "intro")
              .sort((a, b) => a.ms - b.ms)[0]
            this.engine.cueTo(d, first ? first.ms : 0)
          },

          applyPitch(d, v) {
            const rate = 0.92 + v * 0.16
            this.engine.setRate(d, rate)
            const lab = byId(`dj-pitchlab-${d}`)
            if (lab) lab.textContent = `${((rate - 1) * 100).toFixed(1)}%`
          },

          setMeter(id, level) {
            const el = byId(id)
            if (el) el.style.height = `${Math.min(Math.round(level * 140), 100)}%`
          },

          paintDeck(d) {
            const deck = this.engine.decks[d]
            const track = this.tracks[d]
            const dur = deck.el.duration
              ? deck.el.duration * 1000
              : (track && track.duration_ms) || 0
            const pos = deck.positionMs()
            const elapsed = byId(`dj-el-${d}`)
            const rem = byId(`dj-rem-${d}`)
            if (elapsed) elapsed.textContent = fmt(pos)
            if (rem) rem.textContent = `−${fmt(Math.max(dur - pos, 0))}`
            const fill = byId(`dj-fill-${d}`)
            if (fill) fill.style.width = dur ? `${Math.min((pos / dur) * 100, 100)}%` : "0%"
            const ring = byId(`dj-jogring-${d}`)
            if (ring) {
              const deg = dur ? (pos / dur) * 360 : 0
              ring.style.background =
                `conic-gradient(${ACCENTS[d]} ${deg}deg, rgba(255,255,255,.06) 0deg)`
            }
            const needle = byId(`dj-needle-${d}`)
            if (needle) {
              const deg = (((deck.el.currentTime || 0) / 1.8) * 360) % 360
              needle.style.transform = `translateX(-50%) rotate(${deg}deg)`
            }
            const icon = byId(`dj-playicon-${d}`)
            if (icon) icon.textContent = deck.audible() ? "⏸" : "▶"
          },

          paintCountdown() {
            const el = byId("dj-countdown")
            if (!el) return
            const hint = this.hint
            const snap = this.engine.snapshot()
            const active = snap.activeDeck
            if (!hint || !hint.transition || !active || !snap[active].playing) {
              el.textContent = "—"
              return
            }
            const remaining = (hint.transition.from_ms || 0) - snap[active].posMs
            el.textContent = remaining > 0 ? `em ${fmt(remaining)}` : "agora"
          },

          applyMidi(a) {
            switch (a.type) {
              case "play":
                if (a.pressed) this.engine.playPause(a.deck)
                break
              case "cue":
                if (a.pressed) this.cue(a.deck)
                break
              case "sync":
                if (a.pressed && this.engine.sync(a.deck)) this.log(`SYNC deck ${a.deck.toUpperCase()} (MIDI)`)
                break
              case "pitch": {
                this.applyPitch(a.deck, a.value)
                const el = byId(`dj-pitch-${a.deck}`)
                if (el) el.value = Math.round(a.value * 100)
                break
              }
              case "level": {
                this.engine.setDeckLevel(a.deck, a.value)
                const el = byId(`dj-level-${a.deck}`)
                if (el) el.value = Math.round(a.value * 100)
                break
              }
              case "crossfader":
                this.engine.setCrossfader(a.value)
                break
              case "master_gain":
                this.engine.setMasterLevel(a.value * 1.2)
                break
              case "hotcue": {
                if (!a.pressed) break
                const pad = byId(`dj-pad-${a.deck}-${a.index}`)
                if (pad && pad.dataset.ms) this.engine.cueTo(a.deck, Number(pad.dataset.ms))
                break
              }
              case "jog_turn":
                this.engine.nudge(a.deck, a.delta * 40)
                break
              case "browse":
                this.moveCursor(a.delta)
                break
              case "load_a":
                if (a.pressed) this.loadCursor("a")
                break
              case "load_b":
                if (a.pressed) this.loadCursor("b")
                break
            }
          },

          moveCursor(delta) {
            const rows = Array.from(document.querySelectorAll("[data-dj-entry]"))
            if (!rows.length) return
            this.cursor = Math.min(Math.max(this.cursor + Math.sign(delta), 0), rows.length - 1)
            rows.forEach((r, i) => {
              r.style.outline = i === this.cursor ? "1px solid #ffb020" : ""
            })
            rows[this.cursor].scrollIntoView({block: "nearest"})
          },

          loadCursor(deck) {
            const rows = Array.from(document.querySelectorAll("[data-dj-entry]"))
            const row = rows[this.cursor]
            if (row) this.pushEvent("load_deck", {deck, track_id: row.dataset.trackId})
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DjMidi">
        import {decode, describe} from "@/js/dj/midi_map.js"

        export default {
          mounted() {
            this._ccAt = {}

            if (!navigator.requestMIDIAccess) {
              this.pushEvent("midi_status", {connected: false, name: null})
              this.monitor("Web MIDI indisponível neste navegador")
              return
            }

            navigator
              .requestMIDIAccess()
              .then((access) => {
                this.access = access
                this._refresh = () => this.attachAll()
                access.addEventListener("statechange", this._refresh)
                this.attachAll()
              })
              .catch(() => {
                this.pushEvent("midi_status", {connected: false, name: null})
                this.monitor("acesso MIDI negado pelo navegador")
              })
          },

          destroyed() {
            if (!this.access) return
            this.access.removeEventListener("statechange", this._refresh)
            for (const input of this.access.inputs.values()) {
              input.onmidimessage = null
              input._djAttached = false
            }
          },

          attachAll() {
            const inputs = Array.from(this.access.inputs.values())
            for (const input of inputs) {
              if (input._djAttached) continue
              input._djAttached = true
              input.onmidimessage = (msg) => this.handle(Array.from(msg.data))
            }
            const active = inputs.find((i) => i.state === "connected")
            this.pushEvent("midi_status", {connected: !!active, name: active ? active.name : null})
            if (active) this.monitor(`conectada: ${active.name}`, "#5ad1a0")
          },

          handle(data) {
            if (data.length < 3) return
            const action = decode(data)
            if (!action) {
              this.throttled("raw", () =>
                this.monitor(`? ${data.map((b) => b.toString(16).padStart(2, "0")).join(" ")}`)
              )
              return
            }
            window.dispatchEvent(new CustomEvent("dj:midi", {detail: action}))
            if (action.value != null || action.delta != null) {
              this.throttled(action.type + (action.deck || ""), () => this.monitor(describe(action)))
            } else {
              this.monitor(describe(action))
            }
          },

          // Faders/jog inundam de CC — o monitor mostra no máx. ~7 linhas/s por controle.
          throttled(key, fn) {
            const now = performance.now()
            if (this._ccAt[key] && now - this._ccAt[key] < 150) return
            this._ccAt[key] = now
            fn()
          },

          monitor(text, color) {
            const log = document.getElementById("dj-midi-log")
            if (!log) return
            const line = document.createElement("p")
            line.textContent = text
            if (color) line.style.color = color
            log.prepend(line)
            while (log.children.length > 20) log.lastChild.remove()
          },
        }
      </script>
    </.app_shell>
    """
  end

  # ── componentes ──────────────────────────────────────────────────────────────

  attr :d, :string, required: true
  attr :track, :map, default: nil
  attr :active, :boolean, default: false
  attr :accent, :string, required: true

  defp deck_panel(assigns) do
    eff = assigns.track && Library.effective(assigns.track)
    assigns = assign(assigns, bpm: eff && eff.bpm, camelot: eff && eff.camelot)

    ~H"""
    <section
      class="rounded-2xl border p-4 transition-colors"
      style={"background:linear-gradient(180deg,#11131a,#0e0f15);box-shadow:0 10px 30px rgba(0,0,0,.35);border-color:#{if @active, do: @accent <> "66", else: "rgba(255,255,255,.08)"}"}
    >
      <div class="flex items-center justify-between">
        <span
          class="rounded-md px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.16em]"
          style={"background:#{@accent}22;color:#{@accent}"}
        >
          Deck {String.upcase(@d)}
        </span>
        <div class="flex items-center gap-1.5">
          <span
            :if={@bpm}
            class="rounded-md bg-white/5 px-2 py-0.5 font-mono text-[11px] text-ink-secondary"
          >
            {bpm_text(@bpm)} BPM
          </span>
          <.camelot_seal value={@camelot} />
        </div>
      </div>

      <div class="mt-3 flex min-h-[44px] items-center gap-2.5">
        <.cover :if={@track} src={cover_src(@track)} artist={@track.tag_artist} size={40} />
        <div :if={@track} class="min-w-0">
          <.link
            navigate={~p"/track/#{@track.id}"}
            class="block truncate text-[13px] font-medium text-ink hover:text-primary"
          >
            {@track.tag_title || @track.filename}
          </.link>
          <p class="truncate text-[11px] text-ink-muted">{@track.tag_artist || "—"}</p>
        </div>
        <p :if={!@track} class="text-[12px] text-ink-faint">
          Deck vazio — carregue uma faixa pela fila do set.
        </p>
      </div>

      <div id={"dj-client-#{@d}"} phx-update="ignore" class="mt-3">
        <div class="flex items-stretch gap-3">
          <div class="flex flex-1 flex-col items-center gap-3">
            <div class="relative size-36 select-none">
              <div
                id={"dj-jogring-#{@d}"}
                class="absolute inset-0 rounded-full"
                style={"background:conic-gradient(#{@accent} 0deg, rgba(255,255,255,.06) 0deg)"}
              >
              </div>
              <div
                class="absolute inset-[6px] rounded-full border border-white/10"
                style="background:repeating-radial-gradient(circle at 50% 50%, #14161d 0px, #14161d 2px, #0e0f15 2px, #0e0f15 5px)"
              >
                <div
                  id={"dj-needle-#{@d}"}
                  class="absolute left-1/2 top-1/2 h-[46%] w-[2.5px] origin-top -translate-x-1/2 rounded-full"
                  style={"background:linear-gradient(180deg, transparent 30%, #{@accent})"}
                >
                </div>
                <div class="absolute left-1/2 top-1/2 flex size-12 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border border-white/12 bg-input">
                  <span id={"dj-jogbpm-#{@d}"} class="font-mono text-[10px] text-ink-faint"></span>
                </div>
              </div>
            </div>

            <div class="flex w-full items-center justify-between font-mono text-[11px] text-ink-faint">
              <span id={"dj-el-#{@d}"}>0:00</span>
              <span id={"dj-rem-#{@d}"}>−0:00</span>
            </div>

            <div
              id={"dj-strip-#{@d}"}
              class="relative h-2 w-full cursor-pointer overflow-hidden rounded-full bg-base"
              style="box-shadow:inset 0 1px 2px rgba(0,0,0,.7)"
              title="Clique para buscar"
            >
              <div
                id={"dj-fill-#{@d}"}
                class="absolute inset-y-0 left-0"
                style={"width:0%;background:linear-gradient(90deg,#{@accent}55,#{@accent})"}
              >
              </div>
              <div id={"dj-marks-#{@d}"} class="pointer-events-none absolute inset-0"></div>
            </div>

            <div class="flex w-full items-center justify-center gap-2">
              <button
                id={"dj-cue-#{@d}"}
                type="button"
                title="Voltar ao cue"
                class="h-9 w-14 rounded-lg border border-white/10 bg-input text-[10px] font-bold uppercase tracking-wider text-ink-muted transition-colors hover:border-amber/50 hover:text-amber"
              >
                Cue
              </button>
              <button
                id={"dj-play-#{@d}"}
                type="button"
                title="Tocar / pausar"
                class="flex h-12 w-16 items-center justify-center rounded-xl border text-[16px] font-semibold transition-colors"
                style={"border-color:#{@accent}55;background:#{@accent}1a;color:#{@accent}"}
              >
                <span id={"dj-playicon-#{@d}"}>▶</span>
              </button>
              <button
                id={"dj-sync-#{@d}"}
                type="button"
                title="Igualar o tempo ao outro deck"
                class="h-9 w-14 rounded-lg border border-white/10 bg-input text-[10px] font-bold uppercase tracking-wider text-ink-muted transition-colors hover:border-green/50 hover:text-green"
              >
                Sync
              </button>
            </div>

            <div class="grid w-full grid-cols-4 gap-1.5">
              <button
                :for={n <- 1..4}
                id={"dj-pad-#{@d}-#{n}"}
                type="button"
                disabled
                title={"Hot cue #{n}"}
                class="flex h-10 flex-col items-center justify-center rounded-lg border border-white/8 bg-[#101218] text-[9px] font-semibold uppercase text-ink-faint transition-colors disabled:opacity-40"
              >
                <span class="text-[10px]">●</span>
                <span id={"dj-padlab-#{@d}-#{n}"}>—</span>
              </button>
            </div>
          </div>

          <div class="flex w-11 flex-col items-center gap-1.5">
            <span class="text-[9px] font-bold uppercase tracking-wider text-ink-faint">Pitch</span>
            <div
              class="flex h-56 items-center justify-center rounded-md border border-white/8 bg-base px-1"
              style="box-shadow:inset 0 1px 3px rgba(0,0,0,.6)"
            >
              <input
                id={"dj-pitch-#{@d}"}
                type="range"
                min="0"
                max="100"
                value="50"
                aria-label={"Pitch do deck #{String.upcase(@d)}"}
                class="h-52 w-6 cursor-pointer appearance-none bg-transparent"
                style={"writing-mode:vertical-lr;direction:rtl;accent-color:#{@accent}"}
              />
            </div>
            <span id={"dj-pitchlab-#{@d}"} class="font-mono text-[9px] text-ink-faint">0.0%</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :hint, :map, default: nil
  attr :playing, :boolean, default: false

  defp mixer(assigns) do
    ~H"""
    <section
      class="flex flex-col rounded-2xl border border-white/8 p-4"
      style="background:linear-gradient(180deg,#11131a,#0e0f15);box-shadow:0 10px 30px rgba(0,0,0,.35)"
    >
      <div id="dj-mixer" phx-update="ignore" class="flex flex-1 flex-col items-center gap-4">
        <div class="flex items-end justify-center gap-4">
          <div
            :for={{id, lab} <- [{"dj-meter-a", "A"}, {"dj-meter-m", "MST"}, {"dj-meter-b", "B"}]}
            class="flex flex-col items-center gap-1"
          >
            <div class="flex h-24 w-3 items-end overflow-hidden rounded-sm bg-base">
              <div
                id={id}
                class="w-full"
                style="height:0%;background:linear-gradient(180deg,#ff5d6c,#ffb020 30%,#5ad1a0 60%)"
              >
              </div>
            </div>
            <span class="text-[8px] font-bold uppercase tracking-wider text-ink-faint">{lab}</span>
          </div>
        </div>

        <div class="flex justify-center gap-7">
          <div
            :for={{d, accent} <- [{"a", "#8b7bf0"}, {"b", "#2d9cff"}]}
            class="flex flex-col items-center gap-1"
          >
            <div
              class="flex h-24 items-center justify-center rounded-md border border-white/8 bg-base px-1"
              style="box-shadow:inset 0 1px 3px rgba(0,0,0,.6)"
            >
              <input
                id={"dj-level-#{d}"}
                type="range"
                min="0"
                max="100"
                value="100"
                aria-label={"Volume do deck #{String.upcase(d)}"}
                class="h-20 w-6 cursor-pointer appearance-none bg-transparent"
                style={"writing-mode:vertical-lr;direction:rtl;accent-color:#{accent}"}
              />
            </div>
            <span class="text-[8px] font-bold uppercase tracking-wider text-ink-faint">
              {String.upcase(d)}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <span
            id="dj-echo-light"
            data-on="false"
            class="size-2.5 rounded-full bg-white/10 transition-all"
          ></span>
          <span class="text-[9px] font-bold uppercase tracking-[0.18em] text-ink-faint">Echo</span>
        </div>

        <div class="w-full">
          <div class="flex justify-between text-[9px] font-bold">
            <span style="color:#8b7bf0">A</span>
            <span class="text-ink-faint tracking-[0.18em] uppercase">Crossfader</span>
            <span style="color:#2d9cff">B</span>
          </div>
          <input
            id="dj-xfader"
            type="range"
            min="0"
            max="100"
            value="50"
            aria-label="Crossfader"
            class="mt-1 w-full"
            style="accent-color:#e6e9f2"
          />
        </div>
      </div>

      <div :if={@hint} class="mt-4 rounded-xl border border-amber/25 bg-amber/8 p-2.5">
        <div class="flex items-center justify-between gap-2">
          <span class="text-[9px] font-bold uppercase tracking-[0.16em] text-amber">
            Próxima · {t_label(@hint.transition && @hint.transition["type"])}
          </span>
          <span id="dj-countdown-wrap" phx-update="ignore" class="font-mono text-[10px] text-amber">
            <span id="dj-countdown">—</span>
          </span>
        </div>
        <p class="mt-1 truncate text-[12px] font-medium text-ink">
          {@hint.track.tag_title || @hint.track.filename}
        </p>
        <p class="truncate text-[10px] text-ink-muted">{@hint.track.tag_artist || "—"}</p>
      </div>
      <div
        :if={!@hint}
        class="mt-4 rounded-xl border border-white/6 p-2.5 text-center text-[10px] text-ink-faint"
      >
        {if @playing, do: "Última faixa do set", else: "Sem próxima armada"}
      </div>
    </section>
    """
  end

  attr :set, :map, default: nil
  attr :entries, :list, default: []
  attr :pointer_id, :string, default: nil
  attr :hint, :map, default: nil

  defp set_rail(assigns) do
    ~H"""
    <section class="rounded-2xl border border-white/8 bg-surface p-4">
      <div class="flex items-center justify-between">
        <h2 class="text-[11px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
          Fila do set
        </h2>
        <.link
          :if={@set}
          navigate={~p"/set/#{@set.id}"}
          class="text-[11px] font-semibold text-primary hover:underline"
        >
          {@set.name} ({length(@entries)})
        </.link>
      </div>

      <p :if={!@set} class="mt-3 text-[12px] text-ink-faint">
        Escolha um set acima para montar a fila — os botões A/B carregam a faixa no deck.
      </p>

      <ol :if={@set} id="dj-rail" class="mt-2 flex max-h-[420px] flex-col gap-1 overflow-auto pr-1">
        <li
          :for={e <- @entries}
          data-dj-entry
          data-track-id={e.track.id}
          class={[
            "flex items-center gap-2.5 rounded-lg border px-2 py-1.5",
            @pointer_id == e.track.id && "border-primary/40 bg-primary/10",
            @hint && @hint.track.id == e.track.id && @pointer_id != e.track.id &&
              "border-amber/30 bg-amber/6",
            @pointer_id != e.track.id && !(@hint && @hint.track.id == e.track.id) &&
              "border-transparent hover:bg-white/3"
          ]}
        >
          <span class="w-5 text-right font-mono text-[10px] text-ink-faint">{e.position}</span>
          <.cover src={cover_src(e.track)} artist={e.track.tag_artist} size={28} />
          <div class="min-w-0 flex-1">
            <.link
              navigate={~p"/track/#{e.track.id}"}
              class="block truncate text-[12px] font-medium text-ink hover:text-primary"
            >
              {e.track.tag_title || e.track.filename}
            </.link>
            <p class="truncate text-[10px] text-ink-muted">{e.track.tag_artist || "—"}</p>
          </div>
          <span class="font-mono text-[10px] text-ink-faint">
            {bpm_text(Library.effective(e.track).bpm)}
          </span>
          <span
            :if={e.transition}
            class={[
              "rounded px-1.5 py-px text-[9px] font-bold uppercase",
              e.transition["type"] == "echo" && "bg-amber/15 text-amber",
              e.transition["type"] != "echo" && "bg-white/6 text-ink-muted"
            ]}
            title="Transição de entrada desta faixa"
          >
            {t_label(e.transition["type"])}
          </span>
          <div class="flex gap-1">
            <button
              type="button"
              phx-click="load_deck"
              phx-value-deck="a"
              phx-value-track_id={e.track.id}
              title="Carregar no deck A"
              class="flex size-6 items-center justify-center rounded-md border border-white/10 text-[10px] font-bold text-[#8b7bf0] transition-colors hover:border-[#8b7bf0] hover:bg-[#8b7bf0]/15"
            >
              A
            </button>
            <button
              type="button"
              phx-click="load_deck"
              phx-value-deck="b"
              phx-value-track_id={e.track.id}
              title="Carregar no deck B"
              class="flex size-6 items-center justify-center rounded-md border border-white/10 text-[10px] font-bold text-[#2d9cff] transition-colors hover:border-[#2d9cff] hover:bg-[#2d9cff]/15"
            >
              B
            </button>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  attr :midi, :map, required: true

  defp midi_panel(assigns) do
    ~H"""
    <section id="dj-midi" phx-hook=".DjMidi" class="rounded-2xl border border-white/8 bg-surface p-4">
      <div class="flex items-center justify-between">
        <h2 class="text-[11px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
          Controladora MIDI
        </h2>
        <span class={[
          "rounded-full px-2 py-0.5 text-[10px] font-semibold",
          @midi.connected && "bg-green/15 text-green",
          !@midi.connected && "bg-white/5 text-ink-faint"
        ]}>
          {(@midi.connected && (@midi.name || "conectada")) || "desconectada"}
        </span>
      </div>
      <p class="mt-1 text-[10px] leading-relaxed text-ink-faint">
        Numark DJ2GO2 Touch via USB — plugue e os controles físicos passam a mexer na mesa
        (play, cue, sync, pitch, volumes, crossfader, pads e o load pelo browse).
      </p>
      <div
        id="dj-midi-log"
        phx-update="ignore"
        class="mt-2 flex max-h-28 flex-col gap-0.5 overflow-auto font-mono text-[10px] text-ink-faint"
      >
      </div>
    </section>
    """
  end
end
