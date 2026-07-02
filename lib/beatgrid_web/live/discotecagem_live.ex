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
  alias Beatgrid.Library.TrackQuery
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Playback
  alias Beatgrid.Sets

  @library_page 50

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
       hint_deck: nil,
       rail_tab: "fila",
       lib_query: "",
       lib_tracks: [],
       midi: %{connected: false, name: nil}
     )}
  end

  # ── seleção e partida ────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_set", %{"set_id" => ""}, socket) do
    # Sem set, a dica antiga não pode continuar armada — a reprodução segue,
    # mas a sequência para na faixa atual.
    {:noreply,
     socket
     |> assign(set: nil, entries: [])
     |> push_event("dj_set", %{id: nil})
     |> push_hint(nil)}
  end

  def handle_event("select_set", %{"set_id" => id}, socket) do
    case Sets.get(id) do
      nil ->
        {:noreply, socket}

      set ->
        socket =
          socket
          |> subscribe_once(set.id)
          |> assign(set: set, entries: Sets.entries(set))
          |> push_event("dj_set", %{id: set.id})

        # Trocar de set no meio da música: a dica armada do set antigo é
        # substituída (ou limpa, se a faixa atual não pertence ao novo set).
        if socket.assigns.playing? && socket.assigns.pointer_id do
          {:noreply, push_hint(socket, Sets.entry_after(set.id, socket.assigns.pointer_id))}
        else
          {:noreply, socket}
        end
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
           pointer_id: first.track.id,
           # dj_stop wipes the client's armed hint — a restart must re-push the
           # same hint, so the dedupe cannot compare against the stale assign
           hint: nil
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

      track = get_track(id) ->
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
        {:noreply, put_flash(socket, :error, "Faixa não encontrada — atualize a lista.")}
    end
  end

  # Ejeta um deck parado (o cliente ainda recusa se estiver audível).
  def handle_event("eject_deck", %{"deck" => deck}, socket) when deck in ["a", "b"] do
    if socket.assigns.playing? and socket.assigns.active_deck == deck do
      {:noreply, put_flash(socket, :error, "Deck #{String.upcase(deck)} está no ar.")}
    else
      {:noreply,
       socket
       |> assign_deck(deck, nil)
       |> push_event("dj_eject", %{deck: deck})}
    end
  end

  # ── fila ↔ biblioteca (o botão do browse alterna; girar navega as linhas) ──

  def handle_event("rail_tab", %{"tab" => tab}, socket) when tab in ["fila", "biblioteca"],
    do: {:noreply, socket |> assign(rail_tab: tab) |> ensure_library_loaded()}

  def handle_event("toggle_rail_tab", _params, socket) do
    tab = if socket.assigns.rail_tab == "fila", do: "biblioteca", else: "fila"
    {:noreply, socket |> assign(rail_tab: tab) |> ensure_library_loaded()}
  end

  def handle_event("search_library", %{"q" => q}, socket),
    do: {:noreply, assign(socket, lib_query: q, lib_tracks: search_library(q))}

  # O cliente avisa quando os DOIS decks silenciaram (pausa manual, fim sem
  # próxima, player global assumiu): o quiet mode não pode ficar preso ligado
  # com a sala em silêncio, e um deck pausado pode receber carga.
  def handle_event("console_idle", _params, socket) do
    Playback.deactivate_quiet_mode()
    {:noreply, assign(socket, playing?: false)}
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
      |> assign(active_deck: deck, playing?: true)
      |> assign_deck_by_id(deck, to_id)

    # Só faixa que PERTENCE ao set vira ponteiro do set — transicionar para uma
    # faixa avulsa da Biblioteca não pode carimbar o set no now-playing.
    case in_set_entry(socket, to_id) do
      nil ->
        Playback.set_now_playing(%{track_id: to_id, set_id: nil})
        {:noreply, push_hint(socket, nil)}

      _entry ->
        set = socket.assigns.set
        Playback.set_now_playing(%{track_id: to_id, set_id: set.id})
        Playback.activate_quiet_mode()

        {:noreply,
         socket
         |> assign(pointer_id: to_id)
         |> push_hint(Sets.entry_after(set.id, to_id))}
    end
  end

  # O cliente armou a dica num deck concreto — cabeçalho do deck + card Próxima.
  def handle_event("hint_armed", %{"deck" => deck, "track_id" => id}, socket)
      when deck in ["a", "b"],
      do: {:noreply, socket |> assign(hint_deck: deck) |> assign_deck_by_id(deck, id)}

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
      deck == socket.assigns.active_deck and not is_nil(next) ->
        # O cliente enfileira a carga se o outro deck ainda estiver soltando a
        # rampa da transição (pendingLoad) — nada de carga recusada e silêncio.
        {:noreply,
         push_event(socket, "dj_load", %{
           deck: other_deck(deck),
           track: track_payload(next.track),
           autoplay: true,
           at_ms: transition_to_ms(next.transition)
         })}

      deck == socket.assigns.active_deck ->
        # A faixa no ar morreu e não há próxima: o silêncio é real — o estado
        # (e o quiet mode!) precisam refletir isso, como em track_ended.
        Playback.set_now_playing(%{track_id: id, set_id: nil})
        Playback.deactivate_quiet_mode()
        {:noreply, assign(socket, playing?: false, active_deck: nil, hint: nil)}

      is_nil(set) ->
        {:noreply, socket}

      true ->
        {:noreply, push_hint(socket, next)}
    end
  end

  # Reconexão de socket: o servidor remonta com assigns zerados, então o
  # CLIENTE é a fonte da verdade — adota set, AUTO e a faixa que segue tocando
  # (sem isso, o remount forçava AUTO ligado e o reabastecimento de dicas parava).
  def handle_event("console_resync", params, socket) do
    socket =
      socket
      |> adopt_resync_set(params["set_id"])
      |> assign(auto?: params["auto"] == true)

    case params do
      %{"playing_track_id" => id, "deck" => deck} when is_binary(id) and is_binary(deck) ->
        handle_event("deck_started", %{"deck" => deck, "track_id" => id}, socket)

      _params ->
        {:noreply, socket}
    end
  end

  def handle_event("midi_status", params, socket) do
    {:noreply,
     assign(socket, midi: %{connected: params["connected"] == true, name: params["name"]})}
  end

  # Edição estrutural do set ao vivo: recarrega a fila e troca a dica armada
  # ANTES da transição disparar — a raiz do bug da festa, agora coberta.
  @impl true
  def handle_info({:set_changed, set_id}, %{assigns: %{set: %{id: set_id} = set}} = socket) do
    old_entries = socket.assigns.entries
    entries = Sets.entries(set)
    socket = assign(socket, entries: entries)

    if socket.assigns.playing? && socket.assigns.pointer_id do
      hint =
        Sets.entry_after(set_id, socket.assigns.pointer_id) ||
          removed_pointer_hint(old_entries, entries, socket.assigns.pointer_id, set_id)

      {:noreply, push_hint(socket, hint)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Saiu da página com a mesa no ar: o áudio morre junto (elementos locais),
  # então anuncia "nada tocando" para as outras telas. Se a mesa estava parada,
  # o player global pode estar tocando — não tocamos no ponteiro dele.
  @impl true
  def terminate(_reason, %{assigns: %{playing?: true}}) do
    Playback.clear_now_playing()
    Playback.deactivate_quiet_mode()
  end

  def terminate(_reason, _socket), do: :ok

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp ensure_library_loaded(%{assigns: %{rail_tab: "biblioteca", lib_tracks: []}} = socket),
    do: assign(socket, lib_tracks: search_library(socket.assigns.lib_query))

  defp ensure_library_loaded(socket), do: socket

  # O limite vai NA QUERY — sem ele, cada tecla materializava a biblioteca
  # inteira (com preloads) para ficar com 50.
  defp search_library(q) do
    filters =
      if q in [nil, ""], do: %{limit: @library_page}, else: %{search: q, limit: @library_page}

    TrackQuery.library(filters)
  end

  # Ids vêm do cliente: um id malformado não pode derrubar a LiveView (o
  # remount destruiria o áudio), e um id sumido vira nil, não crash.
  defp get_track(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> Tracks.get_with_song(id)
      :error -> nil
    end
  end

  defp get_track(_id), do: nil

  defp adopt_resync_set(socket, set_id) when is_binary(set_id) do
    case Sets.get(set_id) do
      nil -> socket
      set -> socket |> subscribe_once(set.id) |> assign(set: set, entries: Sets.entries(set))
    end
  end

  defp adopt_resync_set(socket, _set_id), do: socket

  # A faixa no ar foi REMOVIDA do set no meio da música: a sucessora herda a
  # posição dela — a dica cai para a entrada seguinte ao vizinho anterior que
  # ainda pertence ao set, em vez de matar a sequência.
  defp removed_pointer_hint(old_entries, entries, pointer_id, set_id) do
    member? = fn id -> Enum.any?(entries, &(&1.track.id == id)) end

    with idx when is_integer(idx) <- Enum.find_index(old_entries, &(&1.track.id == pointer_id)),
         prev_id when is_binary(prev_id) <-
           old_entries
           |> Enum.take(idx)
           |> Enum.reverse()
           |> Enum.find_value(fn e -> if member?.(e.track.id), do: e.track.id end) do
      Sets.entry_after(set_id, prev_id)
    else
      _ -> nil
    end
  end

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
      track = get_track(id) -> assign_deck(socket, deck, track)
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
      socket |> assign(hint: nil, hint_deck: nil) |> push_event("dj_hint_clear", %{})
    end
  end

  defp push_hint(socket, hint) do
    if same_hint?(socket.assigns.hint, hint) do
      socket
    else
      socket
      # hint_deck volta quando o cliente confirmar onde armou (hint_armed)
      |> assign(hint: hint, hint_deck: nil)
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
  defp t_label("filter"), do: "FILTRO"
  defp t_label("bass_swap"), do: "GRAVE"
  defp t_label("brake"), do: "FREIO"
  defp t_label("lowpass"), do: "AFUNDA"
  defp t_label(_type), do: "SEQ"

  # The manual-fire palette: {engine key, button label, one-line description, accent}.
  defp transition_buttons do
    [
      {"cut", "Corte", "troca seca", "#e6e9f2"},
      {"fade", "Fade", "desce um, sobe o outro", "#8b7bf0"},
      {"crossfade", "Xfade", "deslize longo com sync", "#2d9cff"},
      {"echo", "Eco", "cauda de delay no tempo", "#ffb020"},
      {"filter", "Filtro", "varredura tira o corpo", "#5ad1a0"},
      {"lowpass", "Afunda", "some embaixo d'água", "#6c5ce7"},
      {"bass_swap", "Grave", "graves trocam de mão", "#ff5d6c"},
      {"brake", "Freio", "o prato para, o outro entra", "#e08e00"}
    ]
  end

  defp bpm_text(bpm) when is_number(bpm), do: bpm |> round() |> Integer.to_string()
  defp bpm_text(_bpm), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:discotecagem} socket={@socket}>
      <div class="mx-auto max-w-7xl px-4 py-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex items-baseline gap-3">
            <h1 class="text-[17px] font-semibold tracking-tight">Discotecagem</h1>
            <p class="hidden text-[11px] text-ink-muted xl:block">
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
              aria-pressed={to_string(@auto?)}
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

        <div id="dj-console" phx-hook=".DjConsole" data-auto={to_string(@auto?)} class="mt-3">
          <div
            id="dj-waves"
            phx-update="ignore"
            class="mb-3 overflow-hidden rounded-xl border border-white/8"
            style="background:linear-gradient(180deg,#0e0f15,#0b0c10)"
          >
            <div class="relative">
              <canvas id="dj-wave-a" class="block w-full cursor-crosshair" style="height:44px"></canvas>
              <span
                class="pointer-events-none absolute left-2 top-1 text-[9px] font-bold uppercase tracking-wider"
                style="color:#8b7bf0"
              >
                A
              </span>
            </div>
            <div class="relative border-t border-white/5">
              <canvas id="dj-wave-b" class="block w-full cursor-crosshair" style="height:44px"></canvas>
              <span
                class="pointer-events-none absolute left-2 top-1 text-[9px] font-bold uppercase tracking-wider"
                style="color:#2d9cff"
              >
                B
              </span>
            </div>
          </div>

          <div class="grid gap-3 lg:grid-cols-[1fr_200px_1fr]">
            <.deck_panel
              d="a"
              track={@deck_a}
              active={@playing? and @active_deck == "a"}
              accent="#8b7bf0"
            />
            <.mixer hint={@hint} hint_deck={@hint_deck} playing={@playing?} in_set={@set != nil} />
            <.deck_panel
              d="b"
              track={@deck_b}
              active={@playing? and @active_deck == "b"}
              accent="#2d9cff"
            />
          </div>
          <div class="mt-2 grid items-start gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(320px,380px)]">
            <div class="flex min-w-0 flex-col gap-2.5">
              <details
                id="dj-details-trans"
                open
                class="rounded-xl border border-white/8"
                style="background:linear-gradient(180deg,#11131a,#0e0f15)"
              >
                <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2">
                  <div class="flex items-center gap-2">
                    <span class="text-[10px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
                      Transições
                    </span>
                    <span
                      id="dj-tdir-wrap"
                      phx-update="ignore"
                      class="rounded-md bg-white/5 px-2 py-0.5 font-mono text-[11px]"
                      title="Deck no ar (lado do crossfader) ▸ deck de destino"
                    >
                      <span id="dj-tdir" class="text-ink-faint">—</span>
                    </span>
                    <span
                      id="dj-tlen-wrap"
                      phx-update="ignore"
                      class="flex items-center gap-1 opacity-40 transition-opacity hover:opacity-100"
                      title="Comprimento das transições (segundos, aceita quebrado)"
                    >
                      <input
                        id="dj-tlen"
                        type="range"
                        min="1.5"
                        max="20"
                        step="0.1"
                        value="8"
                        aria-label="Comprimento das transições"
                        class="h-1 w-14 cursor-pointer"
                        style="accent-color:#8b7bf0"
                      />
                      <input
                        id="dj-tlen-num"
                        type="number"
                        min="1.5"
                        max="20"
                        step="0.1"
                        value="8"
                        aria-label="Comprimento em segundos"
                        class="w-8 border-0 bg-transparent p-0 text-right font-mono text-[10px] text-ink-secondary focus:outline-none [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none"
                      />
                      <span class="text-[9px] text-ink-faint">s</span>
                    </span>
                  </div>
                  <span class="text-[9px] text-ink-faint">
                    {if @auto?, do: "AUTO fura a fila", else: "clique dispara"}
                  </span>
                </summary>
                <div id="dj-transitions" phx-update="ignore" class="flex flex-wrap gap-1.5 px-3 pb-3">
                  <button
                    :for={{key, label, desc, color} <- transition_buttons()}
                    type="button"
                    data-dj-fire={key}
                    title={desc}
                    disabled
                    class="flex-1 rounded-lg border border-white/8 bg-[#101218] px-2 py-1.5 text-[10px] font-bold uppercase tracking-wider transition-all disabled:opacity-35"
                    style={"--tc:#{color};color:#{color};min-width:58px"}
                  >
                    {label}
                  </button>
                </div>
              </details>

              <details
                id="dj-details-fx"
                class="rounded-xl border border-white/8"
                style="background:linear-gradient(180deg,#11131a,#0e0f15)"
              >
                <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2">
                  <span class="text-[10px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
                    Efeitos
                  </span>
                  <span class="text-[9px] text-ink-faint">filtro · eco · tom · punch ▾</span>
                </summary>
                <div
                  id="dj-fx"
                  phx-update="ignore"
                  class="grid items-stretch gap-2 px-3 pb-3 sm:grid-cols-2"
                >
                  <.fx_cluster d="a" accent="#8b7bf0" />
                  <.fx_cluster d="b" accent="#2d9cff" />
                  <div class="flex items-center gap-2 rounded-xl border border-white/6 bg-[#101218] px-3 py-2 sm:col-span-2">
                    <span class="text-[9px] font-bold uppercase tracking-[0.16em] text-coral">
                      Punch
                    </span>
                    <input
                      id="dj-punch"
                      type="range"
                      min="0"
                      max="100"
                      value="0"
                      aria-label="Punch do master"
                      class="flex-1"
                      style="accent-color:#ff5d6c"
                    />
                    <span class="text-[9px] text-ink-faint">estoura o master</span>
                  </div>
                </div>
              </details>

              <details
                class="rounded-xl border border-white/8"
                style="background:linear-gradient(180deg,#11131a,#0e0f15)"
              >
                <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2">
                  <span class="text-[10px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
                    Controladora & fone
                  </span>
                  <span class={[
                    "size-2 rounded-full",
                    @midi.connected && "bg-green",
                    !@midi.connected && "bg-white/20"
                  ]}></span>
                </summary>
                <.midi_panel midi={@midi} />
              </details>

              <section class="rounded-xl border border-white/8 bg-surface px-3 py-2">
                <span class="text-[10px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
                  Eventos
                </span>
                <div
                  id="dj-log"
                  phx-update="ignore"
                  class="mt-1 flex max-h-24 flex-col gap-0.5 overflow-auto font-mono text-[10px] leading-relaxed text-ink-muted"
                >
                  <p class="text-ink-faint">— mesa pronta —</p>
                </div>
              </section>
            </div>

            <.set_rail
              set={@set}
              entries={@entries}
              pointer_id={@pointer_id}
              hint={@hint}
              rail_tab={@rail_tab}
              lib_query={@lib_query}
              lib_tracks={@lib_tracks}
            />
          </div>

          <div id="dj-audio-rack" phx-update="ignore">
            <audio id="dj-audio-a" preload="auto" class="hidden"></audio>
            <audio id="dj-audio-b" preload="auto" class="hidden"></audio>
          </div>
        </div>
      </div>

      <style>
        #dj-echo-light[data-on="true"] {
          background: #ffb020;
          box-shadow: 0 0 12px #ffb020, 0 0 3px #ffb020;
        }
        #dj-transitions button:not(:disabled) {
          cursor: pointer;
        }
        #dj-transitions button:not(:disabled):hover {
          border-color: var(--tc);
          background: color-mix(in srgb, var(--tc) 10%, #101218);
          box-shadow: 0 0 14px color-mix(in srgb, var(--tc) 25%, transparent);
        }
        summary::-webkit-details-marker {
          display: none;
        }
        details > summary {
          transition: background 0.15s;
        }
        details > summary:hover {
          background: rgba(255, 255, 255, 0.03);
        }
        #dj-pfl-a[data-on="true"],
        #dj-pfl-b[data-on="true"] {
          border-color: #ffb020;
          color: #ffb020;
          background: rgba(255, 176, 32, 0.12);
          box-shadow: 0 0 10px rgba(255, 176, 32, 0.35);
        }
        [id^="dj-loop-"][data-on="true"] {
          border-color: #5ad1a0;
          color: #5ad1a0;
          background: rgba(90, 209, 160, 0.12);
          box-shadow: 0 0 8px rgba(90, 209, 160, 0.3);
        }
        [id^="dj-tom-"][data-on="true"] {
          border-color: #8b7bf0;
          color: #8b7bf0;
          background: rgba(139, 123, 240, 0.12);
        }
      </style>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DjConsole">
        import {createEngine} from "@/js/dj/engine.js"
        import {loadPeaks, drawWave} from "@/js/dj/waveform.js"

        const ACCENTS = {a: "#8b7bf0", b: "#2d9cff"}
        const WAVE_WINDOW_S = 16
        const FIRE_ERRORS = {
          no_audible: "nada no ar — dê play primeiro",
          empty_target: "o outro deck está vazio",
          target_loading: "o outro deck ainda está carregando",
          target_error: "a faixa do outro deck falhou — carregue outra",
          too_fast: "calma — uma transição acabou de disparar",
        }
        // Ordem da paleta: pads SAMPLER da controladora disparam estas — lado
        // esquerdo as 4 primeiras, lado direito as 4 últimas.
        const PAD_TRANSITIONS = ["cut", "fade", "crossfade", "echo", "filter", "lowpass", "bass_swap", "brake"]
        // Anel de foco dos Efeitos: o browse anda por aqui e o cue level ajusta
        // o item focado (sliders absolutos; TOM alterna).
        const FX_RING = [
          {id: "dj-filter-a", label: "Filtro A", kind: "slider", min: -100, max: 100, reset: 0, set: (h, v) => h.engine.setFilter("a", v / 100)},
          {id: "dj-echofx-a", label: "Eco A", kind: "slider", min: 0, max: 100, reset: 0, set: (h, v) => h.engine.setEchoSend("a", v / 100)},
          {id: "dj-tom-a", label: "Tom A", kind: "toggle"},
          {id: "dj-filter-b", label: "Filtro B", kind: "slider", min: -100, max: 100, reset: 0, set: (h, v) => h.engine.setFilter("b", v / 100)},
          {id: "dj-echofx-b", label: "Eco B", kind: "slider", min: 0, max: 100, reset: 0, set: (h, v) => h.engine.setEchoSend("b", v / 100)},
          {id: "dj-tom-b", label: "Tom B", kind: "toggle"},
          {id: "dj-punch", label: "Punch", kind: "slider", min: 0, max: 100, reset: 0, set: (h, v) => h.engine.setPunch(v / 100)},
        ]
        const byId = (id) => document.getElementById(id)
        const fmt = (ms) => {
          if (ms == null || !isFinite(ms)) return "0:00"
          const t = Math.max(Math.floor(ms / 1000), 0)
          return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`
        }

        export default {
          mounted() {
            this.tracks = {a: null, b: null}
            this.waves = {a: null, b: null}
            this.hint = null
            this.pendingHint = null
            this.cursor = -1
            // Foco de seção da controladora: pads MANUAL escolhem ONDE o browse
            // navega e o cue level ajusta. "lista" = comportamento clássico.
            this.focus = {section: "lista", index: 0}

            // ── formas de onda (estilo Serato: playhead fixo, a onda corre) ──
            this.sizeWaves = () => {
              const dpr = window.devicePixelRatio || 1
              for (const d of ["a", "b"]) {
                const c = byId(`dj-wave-${d}`)
                if (!c) continue
                c.width = Math.floor(c.clientWidth * dpr)
                c.height = Math.floor(c.clientHeight * dpr)
              }
            }
            this.sizeWaves()
            window.addEventListener("resize", this.sizeWaves)
            for (const d of ["a", "b"]) {
              byId(`dj-wave-${d}`).addEventListener("click", (e) => {
                const deck = this.engine.decks[d]
                if (deck.trackId == null) return
                const rect = e.currentTarget.getBoundingClientRect()
                const dtS = ((e.clientX - rect.left) / rect.width - 0.5) * WAVE_WINDOW_S
                this.engine.cueTo(d, Math.max((deck.el.currentTime + dtS) * 1000, 0))
              })
            }

            this.engine = createEngine({
              deckElA: byId("dj-audio-a"),
              deckElB: byId("dj-audio-b"),
              callbacks: {
                deckStarted: ({deck, trackId}) => {
                  this.pushEvent("deck_started", {deck, track_id: trackId})
                  window.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "dj-console"}}))
                },
                transitionStarted: ({fromTrackId, toTrackId, type, deck, mode}) => {
                  this.hint = null
                  this.pushEvent("transition_started", {
                    from_track_id: fromTrackId, to_track_id: toTrackId, type, deck,
                  })
                  const tag = mode === "manual" ? " (manual)" : ""
                  this.log(`transição ${type.toUpperCase()}${tag} → deck ${deck.toUpperCase()}`)
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
                // esperando (dirigido a evento — funciona com a aba em segundo plano),
                // reprocessar uma carga recusada, e avisar o servidor se a sala
                // ficou em silêncio (o quiet mode não pode ficar preso ligado).
                deckFreed: () => {
                  if (this.pendingHint) this.armHint(this.pendingHint)
                  if (this.pendingLoad) this.retryPendingLoad()
                  if (!this.engine.decks.a.audible() && !this.engine.decks.b.audible()) {
                    this.pushEvent("console_idle", {})
                  }
                },
                loopState: ({deck, on, startMs, endMs, beats}) => {
                  for (const b of [1, 2, 4, 8]) {
                    const chip = byId(`dj-loop-${deck}-${b}`)
                    if (chip) chip.dataset.on = on && beats === b ? "true" : "false"
                  }
                  const region = byId(`dj-loopregion-${deck}`)
                  if (region) {
                    // Mesma fonte de duração do playhead: a mídia real primeiro
                    // (metadados de VBR mentem), o banco como fallback.
                    const dur =
                      (this.engine.decks[deck].el.duration || 0) * 1000 ||
                      (this.tracks[deck] && this.tracks[deck].duration_ms)
                    if (on && endMs != null && dur) {
                      region.style.left = `${(startMs / dur) * 100}%`
                      region.style.width = `${((endMs - startMs) / dur) * 100}%`
                      region.style.display = "block"
                    } else {
                      region.style.display = "none"
                    }
                  }
                  if (on) {
                    this.log(
                      `loop ${beats ? beats + (beats === 1 ? " tempo" : " tempos") : "manual"} no deck ${deck.toUpperCase()}`
                    )
                  }
                },
                fxReset: ({deck}) => {
                  const filter = byId(`dj-filter-${deck}`)
                  if (filter) filter.value = 0
                  const echofx = byId(`dj-echofx-${deck}`)
                  if (echofx) echofx.value = 0
                  const tom = byId(`dj-tom-${deck}`)
                  if (tom) tom.dataset.on = "false"
                  // resetChain devolve o fader do deck para 1 — o slider tem
                  // que acompanhar, senão o próximo play "estoura" sem aviso.
                  const level = byId(`dj-level-${deck}`)
                  if (level) level.value = 100
                },
                pflState: ({a, b}) => {
                  const btnA = byId("dj-pfl-a")
                  const btnB = byId("dj-pfl-b")
                  if (btnA) btnA.dataset.on = a ? "true" : "false"
                  if (btnB) btnB.dataset.on = b ? "true" : "false"
                  window.dispatchEvent(new CustomEvent("dj:pfl-led", {detail: {a, b}}))
                  this.log(`fone: deck A ${a ? "ligado" : "desligado"} · deck B ${b ? "ligado" : "desligado"}`)
                },
                cueMode: ({mode, maxChannels}) => {
                  this.cueModeNow = mode
                  const el = byId("dj-cue-mode")
                  if (el) {
                    el.textContent =
                      mode === "quad"
                        ? `saída com ${maxChannels} canais — som na 1/2, fone na 3/4 (a saída de fone da controladora)`
                        : `saída estéreo — em “Listar saídas”, mova a mesa para a controladora ou ligue um fone avulso`
                  }
                  // Em quad o cue JÁ sai nos canais 3/4 — o fone avulso é
                  // desligado e escondido para nunca dobrar (nem vazar o cue
                  // nos canais principais de algum dispositivo).
                  const quad = mode === "quad"
                  const cueSel = byId("dj-cue-device")
                  const cueLab = byId("dj-cue-device-label")
                  if (cueSel) {
                    if (quad) {
                      cueSel.classList.add("hidden")
                      if (cueLab) cueLab.classList.add("hidden")
                      const cueAudio = byId("dj-cue-audio")
                      if (cueAudio && !cueAudio.paused) {
                        cueAudio.pause()
                        cueAudio.srcObject = null
                        this.log("fone avulso desligado — o cue agora vai pelos canais 3/4")
                      }
                    } else if (cueSel.options.length) {
                      cueSel.classList.remove("hidden")
                      if (cueLab) cueLab.classList.remove("hidden")
                    }
                  }
                },
              },
            })

            // O engine nasce com AUTO desligado; o servidor renderizou a verdade
            // no atributo — sem isso, montar com AUTO "ligado" seria mentira.
            this.engine.setAuto(this.el.dataset.auto === "true")

            // Comprimento das transições: slider + número (segundos, quebrado ok),
            // guardado no navegador. stopPropagation evita fechar o <details>.
            const tlen = byId("dj-tlen")
            const tnum = byId("dj-tlen-num")
            // Exposto como método: o cue level (foco em Transições) também ajusta.
            this.applyLen = (v) => {
              const s = this.engine.setTransitionLength(Number(v))
              if (isFinite(s)) {
                if (tlen) tlen.value = s
                if (tnum) tnum.value = s.toFixed(1)
                try {
                  localStorage.setItem("dj-tlen", s)
                } catch (_e) {
                  // modo privado / storage cheio — segue sem persistir
                }
              }
            }
            if (tlen && tnum) {
              let saved = 8
              try {
                const raw = parseFloat(localStorage.getItem("dj-tlen"))
                if (isFinite(raw)) saved = raw
              } catch (_e) {
                // idem
              }
              this.applyLen(saved)
              tlen.addEventListener("input", (e) => this.applyLen(e.target.value))
              tnum.addEventListener("change", (e) => this.applyLen(e.target.value))
              for (const el of [tlen, tnum]) {
                el.addEventListener("click", (e) => e.stopPropagation())
                el.addEventListener("pointerdown", (e) => e.stopPropagation())
                el.addEventListener("keydown", (e) => e.stopPropagation())
              }
            }

            // Depuração no console do navegador (e testes sem controladora).
            window.__djEngine = this.engine

            this.handleEvent("dj_load", (payload) => {
              if (!this.applyLoad(payload)) {
                // Deck ainda audível (ex.: soltando a rampa de uma transição
                // quando o entrante deu erro): a carga fica na fila e entra
                // assim que o deck liberar — nunca "recusada" com silêncio.
                this.pendingLoad = payload
                this.log(`deck ${payload.deck.toUpperCase()} ainda no ar — carga na fila`)
              }
            })
            this.handleEvent("dj_set", ({id}) => {
              this.setId = id
            })
            this.handleEvent("dj_eject", ({deck}) => {
              if (!this.engine.eject(deck)) {
                this.log(`deck ${deck.toUpperCase()} está no ar — não dá para ejetar`)
                return
              }
              this.tracks[deck] = null
              this.waves[deck] = null
              if (this.pendingLoad && this.pendingLoad.deck === deck) this.pendingLoad = null
              this.clearDeckStatics(deck)
              this.log(`deck ${deck.toUpperCase()} ejetado`)
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
              this.pendingLoad = null
            })

            for (const d of ["a", "b"]) {
              byId(`dj-play-${d}`).addEventListener("click", () => this.engine.playPause(d))
              byId(`dj-pfl-${d}`).addEventListener("click", () => this.engine.togglePfl(d))
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
              for (const beats of [1, 2, 4, 8]) {
                byId(`dj-loop-${d}-${beats}`).addEventListener("click", () =>
                  this.engine.beatLoop(d, beats)
                )
              }
              const filterEl = byId(`dj-filter-${d}`)
              filterEl.addEventListener("input", (e) =>
                this.engine.setFilter(d, Number(e.target.value) / 100)
              )
              filterEl.addEventListener("dblclick", (e) => {
                e.target.value = 0
                this.engine.setFilter(d, 0)
              })
              byId(`dj-echofx-${d}`).addEventListener("input", (e) =>
                this.engine.setEchoSend(d, Number(e.target.value) / 100)
              )
              byId(`dj-tom-${d}`).addEventListener("click", (e) => {
                const on = e.currentTarget.dataset.on !== "true"
                e.currentTarget.dataset.on = on ? "true" : "false"
                this.engine.setVinylMode(d, on)
                this.log(on ? `TOM (vinil) ligado no deck ${d.toUpperCase()}` : `TOM desligado no deck ${d.toUpperCase()}`)
              })
            }
            byId("dj-punch").addEventListener("input", (e) =>
              this.engine.setPunch(Number(e.target.value) / 100)
            )
            byId("dj-xfader").addEventListener("input", (e) =>
              this.engine.setCrossfader(Number(e.target.value) / 100)
            )
            // Solta o foco ao largar o knob — o guard de activeElement travava
            // o espelhamento das transições automáticas depois de um clique.
            byId("dj-xfader").addEventListener("pointerup", (e) => e.target.blur())

            // The transitions palette: fire NOW, from the crossfader's deck
            // into the other one. Same protocol as AUTO — the server just
            // hears transition_started and advances the pointer.
            this.fireBtns = Array.from(document.querySelectorAll("#dj-transitions [data-dj-fire]"))
            for (const btn of this.fireBtns) {
              btn.addEventListener("click", () => {
                const res = this.engine.fireManual(btn.dataset.djFire)
                if (!res.ok) this.log(FIRE_ERRORS[res.reason] || "transição indisponível")
              })
            }

            // Saídas de áudio: "principal" move a mesa inteira (ctx.setSinkId —
            // na controladora de 4 canais o fone passa a sair na 3/4); o "fone
            // avulso" toca o stream do cue em outro dispositivo (só em estéreo).
            const fillDevices = (sel, devs, placeholder) => {
              sel.innerHTML = ""
              const none = document.createElement("option")
              none.value = ""
              none.textContent = placeholder
              sel.appendChild(none)
              for (const d of devs) {
                const o = document.createElement("option")
                o.value = d.deviceId
                o.textContent = d.label || `Saída ${sel.children.length}`
                sel.appendChild(o)
              }
            }
            byId("dj-cue-pick").addEventListener("click", async () => {
              if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
                this.log("este navegador não expõe as saídas de áudio")
                return
              }
              try {
                // Corrida com timeout: o prompt de permissão pode ficar aberto
                // para sempre — seguimos em frente e listamos o que der.
                const tmp = await Promise.race([
                  navigator.mediaDevices.getUserMedia({audio: true}),
                  new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 3000)),
                ])
                tmp.getTracks().forEach((t) => t.stop())
              } catch (_e) {
                // sem a permissão os dispositivos podem vir sem id/nome
              }
              let devs = []
              try {
                devs = (await navigator.mediaDevices.enumerateDevices()).filter(
                  (d) => d.kind === "audiooutput" && d.deviceId
                )
              } catch (_e) {
                // fica vazio e avisamos abaixo
              }
              if (!devs.length) {
                this.log("nenhuma saída listável — permita o microfone para liberar a lista")
                return
              }
              fillDevices(byId("dj-out-device"), devs, "— saída principal —")
              fillDevices(byId("dj-cue-device"), devs, "— saída do fone —")
              byId("dj-out-device").classList.remove("hidden")
              byId("dj-out-device-label").classList.remove("hidden")
              if (this.cueModeNow !== "quad") {
                byId("dj-cue-device").classList.remove("hidden")
                byId("dj-cue-device-label").classList.remove("hidden")
              }
              this.log(
                devs.length === 1
                  ? "1 saída de áudio encontrada"
                  : `${devs.length} saídas de áudio encontradas`
              )
            })
            byId("dj-out-device").addEventListener("change", async (e) => {
              if (!e.target.value) return
              try {
                const {mode} = await this.engine.setOutputDevice(e.target.value)
                this.log(
                  mode === "quad"
                    ? "mesa na nova saída — fone pelos canais 3/4"
                    : "mesa na nova saída (estéreo)"
                )
              } catch (_err) {
                this.log("não consegui mover a mesa para essa saída")
              }
            })
            byId("dj-cue-device").addEventListener("change", async (e) => {
              if (!e.target.value) return
              if (this.cueModeNow === "quad") {
                this.log("já em 4 canais — o fone sai pelos canais 3/4 da controladora")
                return
              }
              try {
                const cueAudio = byId("dj-cue-audio")
                cueAudio.srcObject = this.engine.cueStream()
                await cueAudio.setSinkId(e.target.value)
                await cueAudio.play()
                this.log("fone ativo na saída escolhida")
              } catch (_err) {
                this.log("não consegui ativar o fone nessa saída")
              }
            })

            this.onMidi = (e) => this.applyMidi(e.detail)
            window.addEventListener("dj:midi", this.onMidi)

            // A controladora conectou (talvez no meio da sessão): manda o
            // estado real do PFL para os LEDs não mentirem.
            this.onPflSync = () =>
              window.dispatchEvent(
                new CustomEvent("dj:pfl-led", {detail: this.engine.pflState()})
              )
            window.addEventListener("dj:pfl-sync", this.onPflSync)

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
              this.paintWaves()
              this.paintCountdown()
              this.paintTransitions()
              if (this.pendingHint) this.armHint(this.pendingHint)
            }
            this.raf = requestAnimationFrame(tick)
          },

          reconnected() {
            // O servidor remontou zerado: manda a verdade do cliente — set,
            // AUTO e o que segue tocando.
            const snap = this.engine.snapshot()
            const deck = snap.a.playing ? "a" : snap.b.playing ? "b" : null
            this.pushEvent("console_resync", {
              deck,
              playing_track_id: deck ? snap[deck].trackId : null,
              auto: snap.auto,
              set_id: this.setId || null,
            })
          },

          destroyed() {
            cancelAnimationFrame(this.raf)
            window.removeEventListener("resize", this.sizeWaves)
            window.removeEventListener("dj:midi", this.onMidi)
            window.removeEventListener("dj:pfl-sync", this.onPflSync)
            window.removeEventListener("beatgrid:playing", this.onForeignPlay)
            if (window.__djEngine === this.engine) window.__djEngine = null
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
            this.loadWave(deck, hint.track)
            this.pushEvent("hint_armed", {deck, track_id: hint.track.id})
            this.log(`próxima armada no deck ${deck.toUpperCase()}: ${hint.track.title}`)
          },

          // Executa uma carga vinda do servidor; false = deck ainda audível.
          applyLoad({deck, track, autoplay, at_ms}) {
            if (!this.engine.loadDeck(deck, track, {autoplay, atMs: at_ms || 0})) return false
            this.pendingLoad = null
            this.tracks[deck] = track
            this.renderDeckStatics(deck, track)
            this.loadWave(deck, track)
            this.log(`deck ${deck.toUpperCase()} ← ${track.title}`)
            return true
          },

          retryPendingLoad() {
            if (this.pendingLoad) this.applyLoad(this.pendingLoad)
          },

          clearDeckStatics(d) {
            const marks = byId(`dj-marks-${d}`)
            if (marks) marks.innerHTML = ""
            for (let n = 1; n <= 4; n++) {
              const pad = byId(`dj-pad-${d}-${n}`)
              const lab = byId(`dj-padlab-${d}-${n}`)
              if (pad) {
                pad.disabled = true
                delete pad.dataset.ms
                pad.style.borderColor = ""
                pad.style.color = ""
              }
              if (lab) lab.textContent = "—"
            }
            const bpmEl = byId(`dj-jogbpm-${d}`)
            if (bpmEl) bpmEl.textContent = ""
          },

          // Decodifica e guarda o envelope de picos; se o deck trocar de faixa
          // no meio, o resultado é descartado (o cache fica para a volta).
          loadWave(deck, track) {
            this.waves[deck] = null
            loadPeaks(track.id, track.src, this.engine.ctx)
              .then((entry) => {
                if (this.tracks[deck] && this.tracks[deck].id === track.id) {
                  this.waves[deck] = entry
                }
              })
              .catch(() => {
                // Memo de falha: a lane não pode dizer "decodificando" para sempre.
                if (this.tracks[deck] && this.tracks[deck].id === track.id) {
                  this.waves[deck] = {failed: true}
                }
                this.log(`sem forma de onda para ${track.title}`)
              })
          },

          paintWaves() {
            for (const d of ["a", "b"]) {
              const canvas = byId(`dj-wave-${d}`)
              if (!canvas) continue
              const deck = this.engine.decks[d]
              const track = this.tracks[d]
              const markers = (track && track.markers) || []
              const intro = markers.find((m) => m.type === "intro" || m.type === "cue")
              const wave = this.waves[d]
              const failed = wave && wave.failed
              drawWave(canvas, {
                entry: failed ? null : wave,
                posS: deck.el.currentTime || 0,
                playing: deck.audible(),
                accent: ACCENTS[d],
                windowS: WAVE_WINDOW_S,
                bpm: track && track.bpm ? track.bpm * deck.el.playbackRate : null,
                gridPhaseMs: intro ? intro.ms : 0,
                markers,
                loop: this.engine.loopState(d),
                label:
                  track && failed
                    ? `sem forma de onda para ${track.title}`
                    : track
                      ? `decodificando ${track.title}…`
                      : "",
              })
            }
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
            // BPM efetivo AO VIVO (muda com pitch/sync/bend) + o alvo do outro
            // deck, para casar tempos na mão vendo os dois números.
            const bpmEl = byId(`dj-jogbpm-${d}`)
            if (bpmEl && track && track.bpm) {
              bpmEl.textContent = (track.bpm * deck.el.playbackRate).toFixed(1)
            }
            const target = byId(`dj-target-${d}`)
            if (target) {
              const o = d === "a" ? "b" : "a"
              const other = this.tracks[o]
              target.textContent =
                other && other.bpm
                  ? `alvo ${(other.bpm * this.engine.decks[o].el.playbackRate).toFixed(1)}`
                  : ""
            }
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
            // O pitch na tela segue o baseRate real — SYNC (botão, MIDI ou o
            // auto-sync do xfade/grave) nunca mais deixa o fader mentindo.
            const pitchLab = byId(`dj-pitchlab-${d}`)
            if (pitchLab) pitchLab.textContent = `${((deck.baseRate - 1) * 100).toFixed(1)}%`
            const pitchEl = byId(`dj-pitch-${d}`)
            if (pitchEl && document.activeElement !== pitchEl) {
              pitchEl.value = Math.round(((deck.baseRate - 0.92) / 0.16) * 100)
            }
          },

          // UI mirror of the manual-fire palette: which direction a click would
          // take (crossfader decides "no ar"), and whether firing makes sense.
          paintTransitions() {
            const from = this.engine.audibleDeck()
            const to = from ? (from === "a" ? "b" : "a") : null
            const ready = !!(from && this.tracks[to])
            const chip = byId("dj-tdir")
            if (chip) {
              if (ready) {
                chip.textContent = `${from.toUpperCase()} ▸ ${to.toUpperCase()}`
                chip.style.color = ACCENTS[from]
              } else {
                chip.textContent = "—"
                chip.style.color = ""
              }
            }
            for (const btn of this.fireBtns || []) btn.disabled = !ready
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
            // Com AUTO desligado ninguém vai disparar sozinho — não prometa.
            if (!snap.auto) {
              el.textContent = "manual"
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
              case "sampler": {
                // Pads em modo SAMPLER = a paleta de transições: lado esquerdo
                // as 4 primeiras, lado direito as 4 últimas.
                if (!a.pressed) break
                const idx = (a.deck === "a" ? 0 : 4) + a.index - 1
                const res = this.engine.fireManual(PAD_TRANSITIONS[idx])
                if (!res.ok) this.log(FIRE_ERRORS[res.reason] || "transição indisponível")
                break
              }
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
              case "pfl":
                if (a.pressed) this.engine.togglePfl(a.deck)
                break
              case "cue_gain":
                this.applyCueKnob(a.value)
                break
              case "hotcue": {
                if (!a.pressed) break
                const pad = byId(`dj-pad-${a.deck}-${a.index}`)
                if (pad && pad.dataset.ms) this.engine.cueTo(a.deck, Number(pad.dataset.ms))
                break
              }
              case "autoloop":
                if (a.pressed) this.engine.beatLoop(a.deck, [1, 2, 4, 8][a.index - 1])
                break
              case "focus":
                // Pads MANUAL: 1 Biblioteca · 2 Efeitos · 3 Transições · 4 Fila.
                if (a.pressed) {
                  const target = [
                    ["lista", "biblioteca"],
                    ["efeitos", null],
                    ["transicoes", null],
                    ["lista", "fila"],
                  ][a.index - 1]
                  if (target) this.setFocusSection(target[0], target[1])
                }
                break
              case "jog_touch":
                this.engine.jogTouch(a.deck, a.pressed)
                break
              case "jog_turn":
                this.engine.jogTurn(a.deck, a.delta)
                break
              case "browse":
                if (this.focus.section === "lista") this.moveCursor(a.delta)
                else this.moveFocus(a.delta)
                break
              case "browse_press":
                // Ação do foco: na lista alterna Fila ↔ Biblioteca; nos efeitos
                // alterna/zera o item; nas transições DISPARA a focada.
                if (a.pressed) this.focusAction()
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
            this.applyCursorOutline(rows)
            rows[this.cursor].scrollIntoView({block: "nearest"})
          },

          applyCursorOutline(rows) {
            rows = rows || Array.from(document.querySelectorAll("[data-dj-entry]"))
            rows.forEach((r, i) => {
              r.style.outline = i === this.cursor ? "1px solid #ffb020" : ""
            })
          },

          // As linhas da fila são re-renderizadas pelo servidor — o contorno do
          // cursor MIDI é reaplicado a cada patch para não sumir. Trocar de aba
          // (fila ↔ biblioteca) zera o cursor: a lista embaixo é outra.
          updated() {
            const panel = byId("dj-rail-panel")
            const tab = panel ? panel.dataset.tab : null
            if (tab !== this._railTab) {
              this._railTab = tab
              this.cursor = -1
              this.applyCursorOutline()
              return
            }
            if (this.cursor >= 0) this.applyCursorOutline()
          },

          loadCursor(deck) {
            const rows = Array.from(document.querySelectorAll("[data-dj-entry]"))
            if (this.cursor >= rows.length) this.cursor = rows.length - 1
            const row = rows[this.cursor]
            if (row) this.pushEvent("load_deck", {deck, track_id: row.dataset.trackId})
            else this.log("gire o browse para escolher uma faixa antes do LOAD")
          },

          // ── foco de seção (controladora sem trackpad) ──────────────────────

          focusRing() {
            if (this.focus.section === "efeitos") {
              return FX_RING.map((f) => byId(f.id)).filter(Boolean)
            }
            if (this.focus.section === "transicoes") return this.fireBtns || []
            return []
          },

          setFocusSection(name, railTab) {
            this.clearFocusOutline()
            this.focus = {section: name, index: 0}
            if (railTab) this.pushEvent("rail_tab", {tab: railTab})
            const detailsId = {efeitos: "dj-details-fx", transicoes: "dj-details-trans"}[name]
            if (detailsId) {
              const d = byId(detailsId)
              if (d) d.open = true
            }
            this.applyFocusOutline()
            const label = {
              lista: railTab === "biblioteca" ? "Biblioteca" : "Fila do set",
              efeitos: "Efeitos",
              transicoes: "Transições",
            }[name]
            this.log(`foco: ${label} — browse navega, cue level ajusta`)
          },

          moveFocus(delta) {
            const ring = this.focusRing()
            if (!ring.length) return
            this.focus.index = Math.min(
              Math.max(this.focus.index + Math.sign(delta), 0),
              ring.length - 1
            )
            this.applyFocusOutline()
          },

          applyFocusOutline() {
            const ring = this.focusRing()
            ring.forEach((el, i) => {
              const on = i === this.focus.index
              el.style.outline = on ? "2px solid #ffb020" : ""
              el.style.outlineOffset = on ? "2px" : ""
            })
            const focused = ring[this.focus.index]
            if (focused) focused.scrollIntoView({block: "nearest"})
          },

          clearFocusOutline() {
            for (const el of this.focusRing()) {
              el.style.outline = ""
              el.style.outlineOffset = ""
            }
          },

          // Apertar o knob do browse = "ação" do item focado.
          focusAction() {
            if (this.focus.section === "lista") {
              this.pushEvent("toggle_rail_tab", {})
              return
            }
            if (this.focus.section === "transicoes") {
              const btn = (this.fireBtns || [])[this.focus.index]
              if (btn && !btn.disabled) btn.click()
              else this.log("transição indisponível — nada no ar ou deck vazio")
              return
            }
            const spec = FX_RING[this.focus.index]
            const el = spec && byId(spec.id)
            if (!el) return
            if (spec.kind === "toggle") {
              el.click() // o listener do TOM alterna e loga sozinho
            } else {
              el.value = spec.reset
              spec.set(this, spec.reset)
              this.log(`${spec.label} zerado`)
            }
          },

          // Cue level: volume do fone quando o foco está na lista; senão, o
          // VALOR do item focado (efeito, ou o comprimento nas transições).
          applyCueKnob(v) {
            if (this.focus.section === "lista") {
              this.engine.setCueLevel(v * 1.2)
              return
            }
            if (this.focus.section === "transicoes") {
              this.applyLen(1.5 + v * (20 - 1.5))
              return
            }
            const spec = FX_RING[this.focus.index]
            const el = spec && byId(spec.id)
            if (!el) return
            if (spec.kind === "toggle") {
              const want = v >= 0.5
              if ((el.dataset.on === "true") !== want) el.click()
              return
            }
            const value = Math.round(spec.min + v * (spec.max - spec.min))
            el.value = value
            spec.set(this, value)
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DjMidi">
        import {decode, describe} from "@/js/dj/midi_map.js"

        export default {
          mounted() {
            this._ccAt = {}

            // O console avisa quando o PFL muda — acendemos o LED do botão de
            // fone SÓ na controladora (nota em outros aparelhos MIDI tocaria
            // um som de verdade neles).
            this.controllerOuts = () => {
              if (!this.access) return []
              return Array.from(this.access.outputs.values()).filter((o) =>
                /dj2go|numark/i.test(o.name || "")
              )
            }
            this.onPflLed = (e) => {
              for (const out of this.controllerOuts()) {
                out.send([0x90, 0x1b, e.detail.a ? 127 : 0])
                out.send([0x91, 0x1b, e.detail.b ? 127 : 0])
              }
            }
            window.addEventListener("dj:pfl-led", this.onPflLed)

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
            window.removeEventListener("dj:pfl-led", this.onPflLed)
            if (!this.access) return
            // Apaga os LEDs de fone — o engine morre junto com a página.
            for (const out of this.controllerOuts()) {
              out.send([0x90, 0x1b, 0])
              out.send([0x91, 0x1b, 0])
            }
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
            if (active) {
              this.monitor(`conectada: ${active.name}`, "#5ad1a0")
              // Sincroniza os LEDs de fone com o estado real do console.
              window.dispatchEvent(new CustomEvent("dj:pfl-sync"))
            }
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
      class="rounded-2xl border p-2 transition-colors"
      style={"background:linear-gradient(180deg,#11131a,#0e0f15);box-shadow:0 10px 30px rgba(0,0,0,.35);border-color:#{if @active, do: @accent <> "66", else: "rgba(255,255,255,.08)"}"}
    >
      <div class="flex items-center justify-between gap-1">
        <span
          class="rounded-md px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em]"
          style={"background:#{@accent}22;color:#{@accent}"}
        >
          Deck {String.upcase(@d)}
        </span>
        <div class="flex flex-wrap items-center justify-end gap-1">
          <span
            :if={@bpm}
            class="rounded-md bg-white/5 px-1.5 py-0.5 font-mono text-[10px] text-ink-secondary"
          >
            {bpm_text(@bpm)} BPM
          </span>
          <.camelot_seal value={@camelot} />
          <span
            :if={@track && @track.rating}
            class="rounded-md bg-white/5 px-1.5 py-0.5 font-mono text-[10px] font-bold"
            style={"color:#{rating_color(@track.rating)}"}
            title="Nota"
          >
            {@track.rating}
          </span>
          <.folder_badge :if={@track && @track.genre_folder} folder={@track.genre_folder} />
        </div>
      </div>

      <div class="mt-2 flex min-h-[36px] items-center gap-2">
        <.cover :if={@track} src={cover_src(@track)} artist={@track.tag_artist} size={32} />
        <div :if={@track} class="min-w-0">
          <.link
            navigate={~p"/track/#{@track.id}"}
            class="block truncate text-[12px] font-medium text-ink hover:text-primary"
          >
            {@track.tag_title || @track.filename}
          </.link>
          <p class="truncate text-[10px] text-ink-muted">{@track.tag_artist || "—"}</p>
        </div>
        <p :if={!@track} class="text-[11px] text-ink-faint">
          Deck vazio — carregue pela fila do set ou pela Biblioteca.
        </p>
        <button
          :if={@track}
          type="button"
          phx-click="eject_deck"
          phx-value-deck={@d}
          title="Ejetar o deck (só quando parado)"
          class="ml-auto flex size-5 shrink-0 items-center justify-center rounded-md text-[10px] text-ink-faint transition-colors hover:bg-white/5 hover:text-coral"
        >
          ✕
        </button>
      </div>

      <div id={"dj-client-#{@d}"} phx-update="ignore" class="mt-2">
        <div class="flex items-stretch gap-2.5">
          <div class="flex flex-1 flex-col items-center gap-2">
            <div class="relative size-20 select-none">
              <div
                id={"dj-jogring-#{@d}"}
                class="absolute inset-0 rounded-full"
                style={"background:conic-gradient(#{@accent} 0deg, rgba(255,255,255,.06) 0deg)"}
              >
              </div>
              <div
                class="absolute inset-[4px] rounded-full border border-white/10"
                style="background:repeating-radial-gradient(circle at 50% 50%, #14161d 0px, #14161d 2px, #0e0f15 2px, #0e0f15 5px)"
              >
                <div
                  id={"dj-needle-#{@d}"}
                  class="absolute left-1/2 top-1/2 h-[46%] w-[2px] origin-top -translate-x-1/2 rounded-full"
                  style={"background:linear-gradient(180deg, transparent 30%, #{@accent})"}
                >
                </div>
                <div class="absolute left-1/2 top-1/2 flex size-10 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border border-white/12 bg-input">
                  <span id={"dj-jogbpm-#{@d}"} class="font-mono text-[9px] text-ink-secondary"></span>
                </div>
              </div>
            </div>

            <div class="flex w-full items-center justify-between font-mono text-[10px] text-ink-faint">
              <span id={"dj-el-#{@d}"}>0:00</span>
              <span
                id={"dj-target-#{@d}"}
                class="text-[9px] text-ink-muted"
                title="BPM ao vivo do outro deck"
              ></span>
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
              <div
                id={"dj-loopregion-#{@d}"}
                class="pointer-events-none absolute inset-y-0 rounded-sm"
                style="display:none;background:rgba(90,209,160,.35);border:1px solid rgba(90,209,160,.7)"
              >
              </div>
              <div id={"dj-marks-#{@d}"} class="pointer-events-none absolute inset-0"></div>
            </div>

            <div class="flex w-full items-center justify-center gap-1.5">
              <button
                id={"dj-cue-#{@d}"}
                type="button"
                title="Voltar ao cue"
                class="h-8 w-12 rounded-lg border border-white/10 bg-input text-[9px] font-bold uppercase tracking-wider text-ink-muted transition-colors hover:border-amber/50 hover:text-amber"
              >
                Cue
              </button>
              <button
                id={"dj-play-#{@d}"}
                type="button"
                title="Tocar / pausar"
                class="flex h-9 w-14 items-center justify-center rounded-lg border text-[14px] font-semibold transition-colors"
                style={"border-color:#{@accent}55;background:#{@accent}1a;color:#{@accent}"}
              >
                <span id={"dj-playicon-#{@d}"}>▶</span>
              </button>
              <button
                id={"dj-sync-#{@d}"}
                type="button"
                title="Igualar o tempo ao outro deck"
                class="h-8 w-12 rounded-lg border border-white/10 bg-input text-[9px] font-bold uppercase tracking-wider text-ink-muted transition-colors hover:border-green/50 hover:text-green"
              >
                Sync
              </button>
              <button
                id={"dj-pfl-#{@d}"}
                type="button"
                data-on="false"
                title="Escutar este deck no fone (pré-fader) — botão de fone na controladora"
                class="h-8 w-9 rounded-lg border border-white/10 bg-input text-[12px] text-ink-muted transition-colors hover:border-amber/50 hover:text-amber"
              >
                🎧
              </button>
            </div>

            <div class="grid w-full grid-cols-4 gap-1">
              <button
                :for={n <- 1..4}
                id={"dj-pad-#{@d}-#{n}"}
                type="button"
                disabled
                title={"Hot cue #{n}"}
                class="flex h-7 items-center justify-center rounded-md border border-white/8 bg-[#101218] text-[9px] font-semibold text-ink-faint transition-colors disabled:opacity-40"
              >
                <span id={"dj-padlab-#{@d}-#{n}"}>—</span>
              </button>
            </div>

            <div class="flex w-full items-center gap-1">
              <span class="w-7 text-[8px] font-bold uppercase tracking-wider text-ink-faint">
                Loop
              </span>
              <button
                :for={beats <- [1, 2, 4, 8]}
                id={"dj-loop-#{@d}-#{beats}"}
                type="button"
                data-on="false"
                title={"Loop de #{beats} #{if beats == 1, do: "tempo", else: "tempos"}"}
                class="h-5 flex-1 rounded-md border border-white/8 bg-[#101218] font-mono text-[9px] font-bold text-ink-faint transition-colors hover:border-green/50 hover:text-green"
              >
                {beats}
              </button>
            </div>
          </div>

          <div class="flex w-9 flex-col items-center gap-1">
            <span class="text-[8px] font-bold uppercase tracking-wider text-ink-faint">Pitch</span>
            <div
              class="flex h-28 items-center justify-center rounded-md border border-white/8 bg-base px-1"
              style="box-shadow:inset 0 1px 3px rgba(0,0,0,.6)"
            >
              <input
                id={"dj-pitch-#{@d}"}
                type="range"
                min="0"
                max="100"
                value="50"
                aria-label={"Pitch do deck #{String.upcase(@d)}"}
                class="h-24 w-5 cursor-pointer appearance-none bg-transparent"
                style={"writing-mode:vertical-lr;direction:rtl;accent-color:#{@accent}"}
              />
            </div>
            <span id={"dj-pitchlab-#{@d}"} class="font-mono text-[8px] text-ink-faint">0.0%</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :hint, :map, default: nil
  attr :hint_deck, :string, default: nil
  attr :playing, :boolean, default: false
  attr :in_set, :boolean, default: false

  defp mixer(assigns) do
    ~H"""
    <section
      class="flex flex-col rounded-2xl border border-white/8 p-3"
      style="background:linear-gradient(180deg,#11131a,#0e0f15);box-shadow:0 10px 30px rgba(0,0,0,.35)"
    >
      <div id="dj-mixer" phx-update="ignore" class="flex flex-1 flex-col items-center gap-2.5">
        <div class="flex items-end justify-center gap-3">
          <div
            :for={{id, lab} <- [{"dj-meter-a", "A"}, {"dj-meter-m", "MST"}, {"dj-meter-b", "B"}]}
            class="flex flex-col items-center gap-0.5"
          >
            <div class="flex h-14 w-2.5 items-end overflow-hidden rounded-sm bg-base">
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

        <div class="flex justify-center gap-6">
          <div
            :for={{d, accent} <- [{"a", "#8b7bf0"}, {"b", "#2d9cff"}]}
            class="flex flex-col items-center gap-0.5"
          >
            <div
              class="flex h-14 items-center justify-center rounded-md border border-white/8 bg-base px-1"
              style="box-shadow:inset 0 1px 3px rgba(0,0,0,.6)"
            >
              <input
                id={"dj-level-#{d}"}
                type="range"
                min="0"
                max="100"
                value="100"
                aria-label={"Volume do deck #{String.upcase(d)}"}
                class="h-11 w-5 cursor-pointer appearance-none bg-transparent"
                style={"writing-mode:vertical-lr;direction:rtl;accent-color:#{accent}"}
              />
            </div>
            <span class="text-[8px] font-bold uppercase tracking-wider text-ink-faint">
              {String.upcase(d)}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-1.5">
          <span
            id="dj-echo-light"
            data-on="false"
            class="size-2 rounded-full bg-white/10 transition-all"
          ></span>
          <span class="text-[8px] font-bold uppercase tracking-[0.18em] text-ink-faint">Eco</span>
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
            class="mt-0.5 w-full"
            style="accent-color:#e6e9f2"
          />
        </div>
      </div>

      <div :if={@hint} class="mt-2 rounded-lg border border-amber/25 bg-amber/8 p-2">
        <div class="flex items-center justify-between gap-2">
          <span class="text-[9px] font-bold uppercase tracking-[0.16em] text-amber">
            Próxima · {t_label(@hint.transition && @hint.transition["type"])}{if @hint_deck,
              do: " · deck #{String.upcase(@hint_deck)}"}
          </span>
          <span id="dj-countdown-wrap" phx-update="ignore" class="font-mono text-[10px] text-amber">
            <span id="dj-countdown">—</span>
          </span>
        </div>
        <p class="mt-0.5 truncate text-[11px] font-medium text-ink">
          {@hint.track.tag_title || @hint.track.filename}
        </p>
        <p class="truncate text-[10px] text-ink-muted">{@hint.track.tag_artist || "—"}</p>
        <p
          :if={@hint.transition && @hint.transition["reason"]}
          class="mt-1 text-[9px] leading-tight text-amber/70"
        >
          {@hint.transition["reason"]}
        </p>
      </div>
      <div
        :if={!@hint}
        class="mt-2 rounded-lg border border-white/6 p-2 text-center text-[10px] text-ink-faint"
      >
        {if @playing && @in_set, do: "Última faixa do set", else: "Sem próxima armada"}
      </div>
    </section>
    """
  end

  attr :set, :map, default: nil
  attr :entries, :list, default: []
  attr :pointer_id, :string, default: nil
  attr :hint, :map, default: nil
  attr :rail_tab, :string, default: "fila"
  attr :lib_query, :string, default: ""
  attr :lib_tracks, :list, default: []

  defp set_rail(assigns) do
    ~H"""
    <section
      id="dj-rail-panel"
      data-tab={@rail_tab}
      class="flex max-h-[calc(100vh-580px)] min-h-[240px] flex-col overflow-hidden rounded-2xl border border-white/8 bg-surface p-3"
    >
      <div class="flex shrink-0 items-center justify-between gap-2">
        <div class="flex items-center gap-1">
          <button
            :for={
              {tab, label} <- [
                {"fila", fila_tab_label(@entries, @pointer_id)},
                {"biblioteca", "Biblioteca"}
              ]
            }
            type="button"
            phx-click="rail_tab"
            phx-value-tab={tab}
            aria-pressed={to_string(@rail_tab == tab)}
            title="O botão do browse na controladora alterna entre as abas"
            class={[
              "rounded-md px-2 py-1 text-[10px] font-bold uppercase tracking-[0.12em] transition-colors",
              @rail_tab == tab && "bg-primary/15 text-primary",
              @rail_tab != tab && "text-ink-faint hover:bg-white/5 hover:text-ink"
            ]}
          >
            {label}
          </button>
        </div>
        <.link
          :if={@rail_tab == "fila" && @set}
          navigate={~p"/set/#{@set.id}"}
          class="truncate text-[11px] font-semibold text-primary hover:underline"
        >
          {@set.name} ({length(@entries)})
        </.link>
        <span :if={@rail_tab == "biblioteca"} class="text-[10px] text-ink-faint">
          gire o browse para navegar · LOAD carrega
        </span>
      </div>

      <p :if={@rail_tab == "fila" && !@set} class="mt-3 text-[12px] text-ink-faint">
        Escolha um set acima para montar a fila — os botões A/B carregam a faixa no deck.
      </p>

      <ol
        :if={@rail_tab == "fila" && @set}
        id="dj-rail"
        class="mt-2 flex min-h-0 flex-1 flex-col gap-1 overflow-auto pr-1"
      >
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
            title={e.transition["reason"] || "Transição de entrada desta faixa"}
          >
            {t_label(e.transition["type"])}
          </span>
          <.load_buttons track_id={e.track.id} />
        </li>
      </ol>

      <div :if={@rail_tab == "biblioteca"} class="flex min-h-0 flex-1 flex-col">
        <form id="dj-lib-search" phx-change="search_library" class="mt-2 shrink-0">
          <input
            type="search"
            name="q"
            value={@lib_query}
            placeholder="Buscar na biblioteca…"
            aria-label="Buscar na biblioteca"
            phx-debounce="250"
            autocomplete="off"
            class="w-full rounded-lg border border-white/10 bg-input px-3 py-1.5 text-[12px] text-ink placeholder:text-ink-faint focus:border-primary/60 focus:outline-none"
          />
        </form>
        <p :if={@lib_tracks == []} class="mt-3 text-[12px] text-ink-faint">
          Nenhuma faixa encontrada.
        </p>
        <ol class="mt-2 flex min-h-0 flex-1 flex-col gap-1 overflow-auto pr-1">
          <li
            :for={t <- @lib_tracks}
            data-dj-entry
            data-track-id={t.id}
            class="flex items-center gap-2.5 rounded-lg border border-transparent px-2 py-1.5 hover:bg-white/3"
          >
            <.cover src={cover_src(t)} artist={t.tag_artist} size={28} />
            <div class="min-w-0 flex-1">
              <.link
                navigate={~p"/track/#{t.id}"}
                class="block truncate text-[12px] font-medium text-ink hover:text-primary"
              >
                {t.tag_title || t.filename}
              </.link>
              <p class="truncate text-[10px] text-ink-muted">{t.tag_artist || "—"}</p>
            </div>
            <span class="font-mono text-[10px] text-ink-faint">
              {bpm_text(Library.effective(t).bpm)}
            </span>
            <.camelot_seal value={Library.effective(t).camelot} />
            <span
              :if={t.rating}
              class="font-mono text-[10px] font-bold"
              style={"color:#{rating_color(t.rating)}"}
            >
              {t.rating}
            </span>
            <.load_buttons track_id={t.id} />
          </li>
        </ol>
        <p :if={length(@lib_tracks) >= 50} class="mt-1.5 text-center text-[10px] text-ink-faint">
          mostrando as primeiras 50 — refine a busca para achar o resto
        </p>
      </div>
    </section>
    """
  end

  # Com o set tocando, a própria aba mostra o progresso (visível mesmo com a
  # Biblioteca aberta): "Fila 7/20".
  defp fila_tab_label(entries, pointer_id) do
    with true <- is_binary(pointer_id),
         idx when is_integer(idx) <- Enum.find_index(entries, &(&1.track.id == pointer_id)) do
      "Fila #{idx + 1}/#{length(entries)}"
    else
      _ -> "Fila do set"
    end
  end

  attr :track_id, :string, required: true

  defp load_buttons(assigns) do
    ~H"""
    <div class="flex gap-1">
      <button
        type="button"
        phx-click="load_deck"
        phx-value-deck="a"
        phx-value-track_id={@track_id}
        title="Carregar no deck A"
        class="flex size-6 items-center justify-center rounded-md border border-white/10 text-[10px] font-bold text-[#8b7bf0] transition-colors hover:border-[#8b7bf0] hover:bg-[#8b7bf0]/15"
      >
        A
      </button>
      <button
        type="button"
        phx-click="load_deck"
        phx-value-deck="b"
        phx-value-track_id={@track_id}
        title="Carregar no deck B"
        class="flex size-6 items-center justify-center rounded-md border border-white/10 text-[10px] font-bold text-[#2d9cff] transition-colors hover:border-[#2d9cff] hover:bg-[#2d9cff]/15"
      >
        B
      </button>
    </div>
    """
  end

  attr :d, :string, required: true
  attr :accent, :string, required: true

  # Cluster de efeitos por deck (conteúdo estático dentro da região ignore do
  # painel Efeitos — o hook liga os listeners e o engine reseta no load).
  defp fx_cluster(assigns) do
    ~H"""
    <div class="rounded-xl border border-white/6 bg-[#101218] p-3">
      <div class="flex items-center justify-between">
        <span
          class="rounded px-1.5 py-px text-[9px] font-bold uppercase tracking-[0.14em]"
          style={"background:#{@accent}22;color:#{@accent}"}
        >
          Deck {String.upcase(@d)}
        </span>
        <button
          id={"dj-tom-#{@d}"}
          type="button"
          data-on="false"
          title="Modo vinil: o pitch passa a mudar a afinação (tom) junto com o tempo"
          class="rounded-md border border-white/10 bg-input px-2 py-0.5 text-[9px] font-bold uppercase tracking-wider text-ink-faint transition-colors hover:text-ink"
        >
          Tom
        </button>
      </div>
      <div class="mt-2 flex items-center gap-2">
        <span class="w-9 text-[9px] font-bold uppercase tracking-wider text-ink-faint">
          Filtro
        </span>
        <input
          id={"dj-filter-#{@d}"}
          type="range"
          min="-100"
          max="100"
          value="0"
          aria-label={"Filtro do deck #{String.upcase(@d)}"}
          title="Esquerda afoga (low-pass), direita só ar (high-pass) — duplo clique volta ao centro"
          class="flex-1"
          style={"accent-color:#{@accent}"}
        />
      </div>
      <div class="mt-1.5 flex items-center gap-2">
        <span class="w-9 text-[9px] font-bold uppercase tracking-wider text-ink-faint">Eco</span>
        <input
          id={"dj-echofx-#{@d}"}
          type="range"
          min="0"
          max="100"
          value="0"
          aria-label={"Eco do deck #{String.upcase(@d)}"}
          title="Abre o delay sincronizado ao BPM da faixa"
          class="flex-1"
          style={"accent-color:#{@accent}"}
        />
      </div>
    </div>
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
        Numark DJ2GO2 Touch via USB — plugue e os controles físicos passam a mexer na mesa:
        play, cue, sync, pitch, volumes, crossfader, o prato (segurar o topo = vinil na mão,
        girar pela borda = ajuste fino), fone e o load pelo browse. Pads: CUES = hot cues ·
        AUTO = loops · MANUAL = seções (1 Biblioteca, 2 Efeitos, 3 Transições, 4 Fila — o
        browse navega a seção e o cue level vira o knob de valor) · SAMPLER = as 8 transições.
      </p>
      <div
        id="dj-midi-log"
        phx-update="ignore"
        class="mt-2 flex max-h-28 flex-col gap-0.5 overflow-auto font-mono text-[10px] text-ink-faint"
      >
      </div>

      <div id="dj-cue-panel" phx-update="ignore" class="mt-3 border-t border-white/6 pt-3">
        <div class="flex items-center justify-between gap-2">
          <h3 class="text-[10px] font-bold uppercase tracking-[0.14em] text-ink-secondary">
            Fone (cue)
          </h3>
          <button
            id="dj-cue-pick"
            type="button"
            class="rounded-md border border-white/10 bg-input px-2 py-0.5 text-[10px] font-semibold text-ink-muted transition-colors hover:border-primary/50 hover:text-primary"
          >
            Listar saídas
          </button>
        </div>
        <p id="dj-cue-mode" class="mt-1 text-[10px] leading-relaxed text-ink-faint">
          verificando a saída de áudio…
        </p>
        <label
          id="dj-out-device-label"
          for="dj-out-device"
          class="mt-1.5 hidden text-[9px] font-bold uppercase tracking-wider text-ink-faint"
        >
          Saída principal (a mesa toda)
        </label>
        <select
          id="dj-out-device"
          class="mt-0.5 hidden w-full rounded-md border border-white/10 bg-input px-2 py-1 text-[10px] text-ink"
        ></select>
        <label
          id="dj-cue-device-label"
          for="dj-cue-device"
          class="mt-1.5 hidden text-[9px] font-bold uppercase tracking-wider text-ink-faint"
        >
          Fone avulso (quando a principal é estéreo)
        </label>
        <select
          id="dj-cue-device"
          class="mt-0.5 hidden w-full rounded-md border border-white/10 bg-input px-2 py-1 text-[10px] text-ink"
        ></select>
        <audio id="dj-cue-audio" class="hidden"></audio>
      </div>
    </section>
    """
  end
end
