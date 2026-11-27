defmodule BeatgridWeb.MixLive do
  @moduledoc "Curadoria: study one recorded online set — segment timeline + transition map."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.GenreFolders
  alias Beatgrid.Mixes
  alias Beatgrid.Mixes.Transition
  alias Beatgrid.Workers.MixAnalyzeWorker

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Mixes.get_with_dj_parts(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "Set não encontrado.") |> push_navigate(to: ~p"/sets-online")}

      mix ->
        if connected?(socket), do: Mixes.subscribe()

        {:ok,
         assign(socket,
           page_title: mix.title || "Set",
           mix: mix,
           progress: nil,
           recorte: nil,
           recorte_initial: nil,
           recorte_version: 0,
           latest_cut: nil,
           folders: GenreFolders.list()
         )}
    end
  end

  @impl true
  def handle_info(
        {:mix_progress, %{stage: "cut_done", mix_id: id, title: title, track_id: track_id}},
        %{assigns: %{mix: %{id: id}}} = socket
      ) do
    {:noreply,
     assign(socket, mix: Mixes.get_with_dj_parts(id), latest_cut: %{id: track_id, title: title})}
  end

  def handle_info(
        {:mix_progress, %{mix_id: id} = payload},
        %{assigns: %{mix: %{id: id}}} = socket
      ) do
    {:noreply,
     assign(socket, mix: Mixes.get_with_dj_parts(id), progress: progress_label(payload))}
  end

  def handle_info({:mix_progress, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "save_segment",
        %{"segment_id" => id, "artist" => artist, "title" => title},
        socket
      ) do
    case Enum.find(socket.assigns.mix.segments, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Segmento não encontrado.")}

      seg ->
        artist = blank_to_nil(artist)
        title = blank_to_nil(title)
        match = Mixes.match_track(artist, title)

        {:ok, _} =
          Mixes.update_segment(seg, %{
            artist: artist,
            title: title,
            name_source: :manual,
            matched_track_id: match && match.track_id,
            match_confidence: match && match.confidence
          })

        {:noreply, assign(socket, mix: Mixes.get_with_dj_parts(socket.assigns.mix.id))}
    end
  end

  def handle_event("reanalyze", _params, socket) do
    mix = socket.assigns.mix

    if playable?(mix) do
      {:ok, _} = Mixes.set_status(mix, :analyzing)
      {:ok, _} = MixAnalyzeWorker.enqueue(mix)
      {:noreply, assign(socket, mix: Mixes.get_with_dj_parts(mix.id))}
    else
      {:noreply, put_flash(socket, :error, "Áudio apagado — não dá pra reanalisar.")}
    end
  end

  def handle_event("delete_audio", _params, socket) do
    {:ok, _} = Mixes.purge_audio(socket.assigns.mix)

    {:noreply,
     socket
     |> put_flash(:info, "Áudio apagado (análise preservada).")
     |> assign(mix: Mixes.get_with_dj_parts(socket.assigns.mix.id))}
  end

  def handle_event("redownload_audio", _params, socket) do
    case Mixes.redownload_audio(socket.assigns.mix) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Baixando o áudio de novo — atualiza quando terminar.")
         |> assign(mix: Mixes.get_with_dj_parts(socket.assigns.mix.id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Não consegui re-baixar o áudio.")}
    end
  end

  def handle_event("analyze_all", _p, socket) do
    case Mixes.analyze_all(socket.assigns.mix) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Analisando tudo — atualiza quando terminar.")
         |> assign(mix: Mixes.get_with_dj_parts(socket.assigns.mix.id))}

      {:error, :no_audio} ->
        {:noreply, put_flash(socket, :error, "Áudio apagado — não dá pra reanalisar.")}
    end
  end

  def handle_event("recognize_all", _params, socket) do
    case Mixes.recognize_unnamed(socket.assigns.mix) do
      {:ok, _} ->
        {:noreply,
         put_flash(socket, :info, "Reconhecimento iniciado — atualiza quando terminar.")}

      {:error, :no_credentials} ->
        {:noreply, put_flash(socket, :error, "Configure AUDD_API_TOKEN no .env.")}
    end
  end

  def handle_event("recognize_retry_all", _params, socket) do
    case Mixes.recognize_unnamed(socket.assigns.mix, true) do
      {:ok, _} ->
        {:noreply,
         put_flash(socket, :info, "Tentando reconhecer tudo de novo — atualiza quando terminar.")}

      {:error, :no_credentials} ->
        {:noreply, put_flash(socket, :error, "Configure AUDD_API_TOKEN no .env.")}
    end
  end

  def handle_event("recognize_seg", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.mix.segments, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Segmento não encontrado.")}

      seg ->
        case Mixes.recognize_segment(seg) do
          {:ok, _} ->
            {:noreply, put_flash(socket, :info, "Reconhecendo a faixa…")}

          {:error, :no_credentials} ->
            {:noreply, put_flash(socket, :error, "Configure AUDD_API_TOKEN no .env.")}
        end
    end
  end

  def handle_event("dj_manual", %{"timestamps" => text}, socket) do
    mix = socket.assigns.mix

    case Mixes.set_dj_parts_manual(mix, text) do
      {:ok, _n} ->
        {:noreply,
         socket
         |> put_flash(:info, "Divisão por DJ aplicada.")
         |> assign(mix: Mixes.get_with_dj_parts(mix.id))}
    end
  end

  def handle_event("dj_chapters", _params, socket) do
    mix = socket.assigns.mix

    case Mixes.set_dj_parts_from_chapters(mix) do
      {:ok, _n} ->
        {:noreply,
         socket
         |> put_flash(:info, "Divisão por DJ aplicada.")
         |> assign(mix: Mixes.get_with_dj_parts(mix.id))}

      {:error, :no_chapters} ->
        {:noreply, put_flash(socket, :error, "Esse set não tem capítulos.")}

      {:error, :manual_present} ->
        {:noreply, put_flash(socket, :error, "Limpe a divisão manual primeiro.")}
    end
  end

  def handle_event("dj_audio", _params, socket) do
    mix = socket.assigns.mix
    {:ok, _job} = Mixes.detect_djs_by_audio(mix)

    {:noreply,
     socket
     |> put_flash(:info, "Detecção iniciada — atualiza quando terminar.")
     |> assign(mix: Mixes.get_with_dj_parts(mix.id))}
  end

  def handle_event("dj_image", _params, socket) do
    mix = socket.assigns.mix
    {:ok, _job} = Mixes.detect_djs_by_image(mix)

    {:noreply,
     socket
     |> put_flash(:info, "Detecção iniciada — atualiza quando terminar.")
     |> assign(mix: Mixes.get_with_dj_parts(mix.id))}
  end

  def handle_event("dj_clear", _params, socket) do
    mix = socket.assigns.mix
    {_deleted, nil} = Mixes.clear_dj_parts(mix)

    {:noreply,
     socket
     |> put_flash(:info, "Divisão por DJ removida.")
     |> assign(mix: Mixes.get_with_dj_parts(mix.id))}
  end

  def handle_event("rename_dj", %{"part_id" => id, "name" => name}, socket) do
    # Ignore the result (a concurrent delete → {:error, :not_found}); the reload reflects reality.
    Mixes.rename_dj_part(id, name)
    {:noreply, assign(socket, mix: Mixes.get_with_dj_parts(socket.assigns.mix.id))}
  end

  def handle_event("delete_dj", %{"id" => id}, socket) do
    Mixes.delete_dj_part(id)

    {:noreply,
     socket
     |> put_flash(:info, "Divisória removida.")
     |> assign(mix: Mixes.get_with_dj_parts(socket.assigns.mix.id))}
  end

  def handle_event("open_recorte", params, socket) do
    seg =
      params["segment"] &&
        Enum.find(socket.assigns.mix.segments, &(&1.id == params["segment"]))

    initial = recorte_prefill(socket.assigns.mix, seg)

    {:noreply,
     assign(socket,
       recorte: initial,
       recorte_initial: initial,
       recorte_version: socket.assigns.recorte_version + 1
     )}
  end

  def handle_event("close_recorte", _params, socket),
    do: {:noreply, assign(socket, recorte: nil, recorte_initial: nil)}

  def handle_event("recorte_mode", %{"mode" => mode}, socket) when mode in ~w(context exact),
    do: {:noreply, assign(socket, recorte: %{socket.assigns.recorte | mode: mode})}

  # Every keystroke keeps the assign in sync so the preview players (and the
  # nudge buttons) always point at the range currently on screen.
  def handle_event("recorte_change", params, socket),
    do: {:noreply, assign(socket, recorte: recorte_from_params(params, socket.assigns.recorte))}

  def handle_event("nudge_recorte", %{"field" => field, "delta" => delta}, socket)
      when field in ~w(start end),
      do: {:noreply, shift_recorte(socket, field, &(&1 + String.to_integer(delta)))}

  # The DJ heard the spot in the preview (the accurate timeline) and marked it.
  def handle_event("mark_recorte", %{"field" => field, "ms" => ms}, socket)
      when field in ~w(start end) and is_integer(ms),
      do: {:noreply, shift_recorte(socket, field, fn _old -> ms end)}

  def handle_event("create_recorte", params, socket) do
    {from, to} = parse_range(params["range"]) || {nil, nil}

    attrs = %{
      start_ms: from,
      end_ms: to,
      artist: params["artist"],
      title: params["title"],
      folder_key: if(params["folder"] == "", do: nil, else: params["folder"]),
      segment_id: socket.assigns.recorte.segment_id
    }

    case Mixes.request_cut(socket.assigns.mix, attrs) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(recorte: nil, recorte_initial: nil)
         |> put_flash(:info, "Recorte na fila para salvar na biblioteca.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(recorte: recorte_from_params(params, socket.assigns.recorte))
         |> put_flash(:error, recorte_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:mixes} socket={@socket}>
      <div id={"mix-study-#{@mix.id}"} data-mix-study class="mx-auto max-w-[1100px] px-3 py-5 sm:px-6">
        <.link
          navigate={~p"/sets-online"}
          class="inline-flex items-center gap-1 text-body-sm text-ink-muted hover:text-ink"
        >
          <.icon name="hero-arrow-left-mini" class="size-4" /> Sets gravados
        </.link>

        <header class="mt-3 min-w-0">
          <div class="flex flex-wrap items-baseline gap-2">
            <h1 class="min-w-0 break-words text-[22px] font-semibold">
              {@mix.title || @mix.source_url}
            </h1>
            <span class={[
              "rounded-xs px-2 py-0.5 text-caption font-semibold",
              mix_status_tone(@mix.status)
            ]}>
              {mix_status_label(@mix.status)}
            </span>
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-body text-ink-secondary">
            <span>{@mix.dj || "DJ desconhecido"}</span>
            <a
              href={@mix.source_url}
              target="_blank"
              rel="noopener"
              class="text-primary hover:underline"
            >{source_link_label(@mix.source)}</a>
          </div>
        </header>

        <dl class="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 border-y border-white/8 py-3 sm:grid-cols-4">
          <div>
            <dt class="text-body-sm text-ink-muted">Duração</dt>
            <dd class="font-mono text-body-lg font-semibold tabular-nums">
              {format_clock(@mix.duration_ms)}
            </dd>
          </div>
          <div>
            <dt class="text-body-sm text-ink-muted">Faixas</dt>
            <dd class="font-mono text-body-lg font-semibold tabular-nums">{length(@mix.segments)}</dd>
          </div>
          <div>
            <dt class="text-body-sm text-ink-muted">Na biblioteca</dt>
            <dd id="mix-coverage" class="font-mono text-body-lg font-semibold tabular-nums">
              {library_coverage(@mix.segments)}%
            </dd>
          </div>
          <div>
            <dt class="text-body-sm text-ink-muted">DJs</dt>
            <dd class="font-mono text-body-lg font-semibold tabular-nums">
              {if @mix.dj_parts == [], do: "—", else: length(@mix.dj_parts)}
            </dd>
          </div>
        </dl>

        <div
          :if={timeline_available?(@mix)}
          id="mix-timeline"
          data-duration-ms={@mix.duration_ms}
          class="mt-3"
        >
          <div class="mb-1 flex flex-wrap items-center justify-between gap-2">
            <h2
              id="mix-timeline-heading"
              tabindex="-1"
              class="scroll-mt-20 text-body-sm font-semibold text-ink-secondary"
            >
              Linha do tempo
            </h2>
            <div class="flex items-center gap-2 text-caption text-ink-muted">
              <span class="flex items-center gap-1"><span class="size-2 rounded-xs bg-green/70"></span>
              Na biblioteca</span>
              <span class="flex items-center gap-1"><span class="size-2 rounded-xs bg-primary/50"></span>
              Outras faixas</span>
            </div>
          </div>
          <div class="relative h-4 overflow-hidden rounded-xs bg-deep" aria-hidden="true">
            <div
              :for={seg <- @mix.segments}
              :if={is_integer(seg.start_ms) && is_integer(seg.end_ms) && seg.end_ms > seg.start_ms}
              data-segment-marker
              class={[
                "absolute inset-y-0 border-r border-base",
                if(seg.matched_track_id, do: "bg-green/70", else: "bg-primary/50")
              ]}
              style={timeline_style(seg, @mix.duration_ms)}
              title={"#{format_clock(seg.start_ms)} · #{seg.title || "Sem nome"}"}
            >
            </div>
            <div
              :if={playable?(@mix)}
              data-timeline-cursor
              class="absolute inset-y-0 left-0 w-px bg-white"
            >
            </div>
          </div>
          <div class="mt-1 flex items-center justify-between gap-2 font-mono text-caption tabular-nums text-ink-muted">
            <span>00:00</span>
            <a
              id="mix-to-tracks"
              href="#mix-tracklist-heading"
              class="font-sans text-body-sm text-primary-soft underline"
            >
              Ver faixas
            </a>
            <span>{format_clock(@mix.duration_ms)}</span>
          </div>
        </div>

        <div :if={@mix.audio_deleted_at} class="mt-3 flex flex-wrap items-center gap-2">
          <p class="text-body-sm text-ink-muted">Áudio apagado (análise preservada).</p>
          <button
            :if={@mix.audio_deleted_at && @mix.status != :downloading}
            phx-click="redownload_audio"
            class="rounded-md border border-primary/30 bg-primary/10 px-3 py-1 text-[12px] font-medium text-primary hover:bg-primary/20"
          >
            Baixar áudio de novo
          </button>
        </div>

        <div
          :if={playable?(@mix)}
          id="mix-player"
          phx-hook=".MixPlayer"
          data-segment-starts={segment_starts(@mix.segments)}
          class="sticky top-0 z-10 mt-3 rounded-lg border border-white/8 bg-surface px-3 py-2"
        >
          <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
            <p class="text-body-sm font-semibold text-ink-secondary">Ouvir gravação</p>
            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                data-mix-prev
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-semibold text-ink-secondary hover:bg-white/10 hover:text-ink"
              >
                Faixa anterior
              </button>
              <button
                type="button"
                data-mix-next
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-semibold text-ink-secondary hover:bg-white/10 hover:text-ink"
              >
                Próxima faixa
              </button>
            </div>
          </div>
          <audio
            id="mix-audio"
            controls
            preload="metadata"
            aria-label="Player do set"
            src={~p"/sets-online/#{@mix.id}/audio"}
            class="w-full"
          />
        </div>

        <details :if={@mix.description not in [nil, ""]} class="mt-3 text-body-sm text-ink-muted">
          <summary class="cursor-pointer text-ink-secondary hover:text-ink">Sobre a gravação</summary>
          <p class="mt-2 max-w-prose whitespace-pre-wrap break-words">{@mix.description}</p>
        </details>

        <p :if={@mix.status == :analyzing} class="mt-4 text-body-sm text-ink-muted">
          Analisando o set… as faixas aparecem quando terminar.
        </p>
        <p :if={@progress} class="mt-1 text-body-sm text-ink-muted font-mono">
          {@progress}
        </p>
        <p :if={@mix.status == :failed} class="mt-4 text-body-sm text-coral">
          {if playable?(@mix),
            do: "A análise falhou. Tente analisar as faixas novamente.",
            else: "Não foi possível baixar o áudio da gravação."}
        </p>

        <div class="mt-4 grid gap-2 md:grid-cols-2 items-start">
          <details class="rounded-lg border border-white/8 bg-surface">
            <summary class="cursor-pointer px-4 py-2 text-body-sm font-medium text-ink-secondary hover:text-ink">
              Análise e arquivo de áudio
            </summary>
            <div class="space-y-3 border-t border-white/8 px-4 py-3">
              <div class="flex flex-wrap items-center gap-2">
                <button
                  phx-click="reanalyze"
                  data-confirm={
                    if @mix.segments != [],
                      do:
                        "A análise irá substituir as faixas e seus vínculos com a biblioteca, inclusive nomes já editados. Recortes salvos serão preservados. Continuar?"
                  }
                  disabled={not playable?(@mix)}
                  title={unless playable?(@mix), do: "Áudio apagado — baixe de novo pra reprocessar"}
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  Reanalisar faixas
                </button>
                <button
                  phx-click="analyze_all"
                  data-confirm={
                    if @mix.segments != [] || @mix.dj_parts != [],
                      do:
                        "A análise irá substituir as faixas e seus vínculos e poderá recalcular a divisão por DJ. Recortes salvos serão preservados. Continuar?"
                  }
                  disabled={not playable?(@mix)}
                  title={unless playable?(@mix), do: "Áudio apagado — baixe de novo pra reprocessar"}
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  Reanalisar faixas e DJs
                </button>
              </div>
              <div :if={playable?(@mix)} class="border-t border-white/8 pt-3">
                <button
                  phx-click="delete_audio"
                  data-confirm="Apagar o áudio deste set? (a análise é preservada)"
                  title="Apagar o arquivo de áudio (mantém a análise)"
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-faint hover:bg-coral/10 hover:text-coral"
                >
                  Apagar áudio baixado
                </button>
              </div>
            </div>
          </details>

          <%!-- DJ panel --%>
          <details class="rounded-lg border border-white/8 bg-surface">
            <summary class="cursor-pointer select-none px-4 py-2 text-body-sm font-medium text-ink-secondary hover:text-ink">
              Divisão por DJ
            </summary>
            <div class="border-t border-white/8 px-4 py-3 space-y-3">
              <form id="dj-manual-form" phx-submit="dj_manual" class="space-y-2">
                <label
                  for="dj-start-times"
                  class="block text-[11px] uppercase tracking-wider text-ink-faint"
                >
                  Horários de entrada dos DJs
                </label>
                <textarea
                  id="dj-start-times"
                  name="timestamps"
                  rows="4"
                  aria-label="Horários de entrada dos DJs"
                  class="w-full rounded border border-white/10 bg-transparent px-2 py-1.5 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary/50 font-mono"
                  placeholder="0:00 DJ A\n30:00 DJ B"
                ></textarea>
                <button
                  type="submit"
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
                >
                  Salvar divisão
                </button>
              </form>
              <div class="flex flex-wrap gap-2">
                <button
                  phx-click="dj_chapters"
                  data-confirm={
                    if @mix.segments != [] || @mix.dj_parts != [],
                      do:
                        "Usar capítulos substitui a divisão por DJ e recalcula a lista de faixas existente. Continuar?"
                  }
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
                >
                  Usar capítulos como DJs
                </button>
                <button
                  phx-click="dj_image"
                  data-confirm={
                    if @mix.dj_parts != [],
                      do: "Detectar novamente poderá substituir a divisão atual por DJs. Continuar?"
                  }
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
                >
                  Detectar por imagem
                </button>
                <button
                  phx-click="dj_audio"
                  data-confirm={
                    if @mix.dj_parts != [],
                      do: "Detectar novamente poderá substituir a divisão atual por DJs. Continuar?"
                  }
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
                >
                  Detectar por áudio
                </button>
                <button
                  phx-click="dj_clear"
                  data-confirm="Remover toda a divisão por DJs desta gravação?"
                  class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
                >
                  Limpar divisão por DJ
                </button>
              </div>
            </div>
          </details>
        </div>

        <section
          class="mt-5 space-y-2"
          aria-labelledby="mix-tracklist-heading"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2
              id="mix-tracklist-heading"
              tabindex="-1"
              class="scroll-mt-20 text-[18px] font-semibold"
            >
              Faixas do set
            </h2>
            <button
              :if={playable?(@mix)}
              id="recorte-open-free"
              type="button"
              phx-click="open_recorte"
              disabled={not is_nil(@recorte)}
              aria-controls="recorte-editor"
              aria-expanded={to_string(not is_nil(@recorte) and is_nil(@recorte.segment_id))}
              class="inline-flex items-center gap-1.5 rounded-md bg-primary-deep px-3 py-1.5 text-body-sm font-semibold text-white hover:bg-primary-deep/90 disabled:opacity-40"
            >
              <span class="hero-scissors size-3.5" aria-hidden="true" /> Recortar trecho
            </button>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              :if={playable?(@mix)}
              phx-click="recognize_all"
              data-confirm="O AudD pode gerar cobrança por faixa consultada. Identificar faixas sem nome?"
              disabled={not Beatgrid.Integrations.configured?(:audd)}
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Reconhecer faixas com AudD
            </button>
            <button
              :if={playable?(@mix) and has_unmatched_attempts?(@mix)}
              phx-click="recognize_retry_all"
              data-confirm="O AudD pode gerar cobrança de novo por faixa consultada. Reconhecer faixas sem nome, inclusive as já consultadas?"
              disabled={not Beatgrid.Integrations.configured?(:audd)}
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Incluir faixas já consultadas
            </button>
            <.integration_gate :if={playable?(@mix)} key={:audd} />
            <a
              :if={timeline_available?(@mix)}
              id="mix-to-timeline"
              href="#mix-timeline-heading"
              class="text-body-sm text-primary-soft underline"
            >
              Linha do tempo
            </a>
          </div>
        </section>

        <div
          :if={@latest_cut}
          role="status"
          class="mt-3 flex flex-wrap items-center gap-2 text-body-sm"
        >
          <span class="text-ink-secondary">Recorte salvo na biblioteca: {@latest_cut.title}</span>
          <.link navigate={~p"/track/#{@latest_cut.id}"} class="text-primary hover:underline">
            Abrir faixa do recorte
          </.link>
        </div>

        <section
          :if={@recorte}
          id="recorte-editor"
          phx-hook=".RecorteDraft"
          data-origin-id={recorte_origin(@recorte_initial.segment_id)}
          data-draft-version={@recorte_version}
          data-initial-range={@recorte_initial.range}
          data-initial-artist={@recorte_initial.artist}
          data-initial-title={@recorte_initial.title}
          data-initial-folder={@recorte_initial.folder || ""}
          aria-labelledby="recorte-title"
          class="mt-4 scroll-mt-36 rounded-xl border border-primary/25 bg-surface p-3 sm:p-4"
        >
          <div class="flex items-center justify-between">
            <h2 id="recorte-title" tabindex="-1" class="text-[18px] font-semibold">Novo recorte</h2>
            <button
              id="recorte-close"
              type="button"
              phx-click="close_recorte"
              aria-label="Fechar recorte"
              data-recorte-confirm="Descartar esta edição de recorte?"
              class="rounded-md border border-white/10 px-2 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
            >
              Fechar
            </button>
          </div>
          <p class="mt-1 text-caption text-ink-muted">
            O recorte gera uma nova faixa MP3 vinculada à gravação original. O arquivo da gravação é preservado.
          </p>

          <div class="mt-4 space-y-4">
            <section>
              <div class="flex items-baseline gap-2">
                <h3 class="text-body-lg font-semibold">
                  <label for="recorte-range">Intervalo do recorte</label>
                </h3>
                <span class="text-caption text-ink-muted">5 segundos a 15 minutos</span>
              </div>

              <div class="mt-1.5 flex flex-wrap items-center gap-2">
                <input
                  id="recorte-range"
                  form="recorte-form"
                  phx-mounted={JS.focus()}
                  name="range"
                  value={@recorte.range}
                  aria-label="Trecho do recorte (início-fim)"
                  placeholder="3:59:14-4:00:50"
                  class="h-10 w-full sm:w-56 rounded-lg border border-white/10 bg-input px-3 font-mono text-body text-ink placeholder:text-ink-faint focus:border-primary"
                />
                <span
                  :if={recorte_range(@recorte)}
                  class="font-mono text-body-sm tabular-nums text-ink-secondary"
                >
                  {recorte_summary(@recorte)}
                </span>
              </div>

              <p
                :if={is_nil(recorte_range(@recorte))}
                class="mt-1.5 font-mono text-caption text-ink-faint"
              >
                aceita 3:59:14-4:00:50 · 59:14 - 1:00:50 · 3:59:14 4:00:50
              </p>

              <div :if={recorte_range(@recorte)} class="mt-2 flex flex-wrap items-center gap-3">
                <div
                  :for={{field, label} <- [{"start", "início"}, {"end", "fim"}]}
                  class="flex items-center gap-1"
                >
                  <span class="w-11 text-caption text-ink-faint">{label}</span>
                  <button
                    :for={{delta, delta_label} <- [{-5000, "−5s"}, {5000, "+5s"}]}
                    type="button"
                    phx-click="nudge_recorte"
                    phx-value-field={field}
                    phx-value-delta={delta}
                    aria-label={"#{delta_label} no #{label}"}
                    class="h-8 w-11 rounded-md border border-white/12 font-mono text-caption text-ink-secondary hover:border-primary/50 hover:text-ink"
                  >
                    {delta_label}
                  </button>
                </div>
              </div>
            </section>

            <section
              :if={recorte_range(@recorte)}
              id="recorte-preview"
              tabindex="0"
              aria-label="Prévia precisa do recorte"
              phx-hook=".RecortePreview"
              data-window-start={recorte_window_start(@recorte)}
              data-range={recorte_canonical(@recorte)}
              data-src={recorte_preview_src(@mix, @recorte, recorte_pad(@recorte))}
            >
              <div class="flex flex-wrap items-baseline gap-2">
                <h3 class="text-body-lg font-semibold">Ouça e marque</h3>
                <div class="flex flex-wrap items-center gap-2 sm:ml-auto">
                  <button
                    type="button"
                    data-recorte-copy
                    class="rounded-md border border-white/10 px-2.5 py-1 text-body-sm text-ink-secondary hover:text-ink"
                  >
                    <.icon name="hero-document-duplicate-mini" class="size-3.5" /> Copiar intervalo
                  </button>
                  <div class="flex rounded-md border border-white/10">
                    <button
                      :for={
                        {mode, label} <- [
                          {"context", "com 15s de contexto"},
                          {"exact", "só o corte"}
                        ]
                      }
                      type="button"
                      phx-click="recorte_mode"
                      phx-value-mode={mode}
                      aria-pressed={to_string(@recorte.mode == mode)}
                      class={[
                        "px-2.5 py-1 text-caption",
                        (@recorte.mode == mode && "bg-primary/20 text-primary") ||
                          "text-ink-muted hover:text-ink"
                      ]}
                    >
                      {label}
                    </button>
                  </div>
                </div>
              </div>
              <span role="status" data-copy-status class="text-caption text-ink-muted"></span>

              <audio
                id="recorte-player"
                controls
                preload="metadata"
                aria-label="Prévia do recorte"
                class="mt-1.5 w-full"
              />

              <div class="mt-2 flex flex-col gap-2 sm:flex-row">
                <button
                  type="button"
                  data-mark="start"
                  title="Onde a prévia está agora vira o início do recorte (tecla I)"
                  class="flex h-11 flex-1 items-center justify-center gap-2 rounded-lg border border-primary/50 bg-primary/10 text-body-sm font-semibold text-primary hover:bg-primary/20"
                >
                  ⟵ marcar início <kbd class="rounded bg-black/30 px-1 font-mono text-[10px]">I</kbd>
                </button>
                <button
                  type="button"
                  data-mark="end"
                  title="Onde a prévia está agora vira o fim do recorte (tecla O)"
                  class="flex h-11 flex-1 items-center justify-center gap-2 rounded-lg border border-primary/50 bg-primary/10 text-body-sm font-semibold text-primary hover:bg-primary/20"
                >
                  marcar fim <kbd class="rounded bg-black/30 px-1 font-mono text-[10px]">O</kbd> ⟶
                </button>
              </div>

              <p class="mt-1.5 text-caption text-ink-faint">
                Use a prévia para acertar os limites. O relógio da gravação inteira pode se deslocar em MP3 longos.
                Com foco na prévia: <b>I</b>
                marca início, <b>O</b>
                marca fim e <b>espaço</b>
                toca/pausa quando a região está focada.
              </p>
            </section>

            <section>
              <div class="flex items-baseline gap-2">
                <h3 class="text-body-lg font-semibold">Nome e destino</h3>
              </div>

              <form
                id="recorte-form"
                phx-change="recorte_change"
                phx-submit="create_recorte"
                class="mt-1.5 grid grid-cols-1 items-end gap-2 sm:grid-cols-12"
              >
                <label class="text-caption text-ink-muted sm:col-span-4">
                  Título da música
                  <input
                    name="title"
                    value={@recorte.title}
                    required
                    placeholder="Osso duro de roer"
                    class="mt-0.5 h-10 w-full rounded-lg border border-white/12 bg-input px-3 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary"
                  />
                </label>
                <label class="text-caption text-ink-muted sm:col-span-4">
                  Artista <span class="text-ink-faint">(opcional)</span>
                  <input
                    name="artist"
                    value={@recorte.artist}
                    placeholder="Os 3 do Nordeste"
                    class="mt-0.5 h-10 w-full rounded-lg border border-white/12 bg-input px-3 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary"
                  />
                </label>
                <label class="text-caption text-ink-muted sm:col-span-2">
                  Pasta
                  <select
                    name="folder"
                    class="mt-0.5 h-10 w-full rounded-lg border border-white/12 bg-input px-2 text-body-sm text-ink focus:border-primary"
                  >
                    <option value="">_Inbox</option>
                    <option :for={f <- @folders} value={f.key} selected={@recorte.folder == f.key}>
                      {f.display_name}
                    </option>
                  </select>
                </label>
                <button
                  type="submit"
                  disabled={is_nil(recorte_range(@recorte))}
                  phx-disable-with="Enfileirando…"
                  class="h-10 rounded-lg bg-primary-deep px-4 text-body-sm font-semibold text-white hover:bg-primary-deep/90 disabled:opacity-40 sm:col-span-2"
                >
                  Salvar MP3
                </button>
              </form>
            </section>
          </div>
        </section>

        <ol :if={@mix.segments != []} id="mix-segments" class="mt-5 space-y-1">
          <%= for {part, segs} <- Mixes.group_by_dj(@mix.segments, @mix.dj_parts) do %>
            <li :if={@mix.dj_parts != []} class="list-none">
              <.dj_divider part={part} count={length(segs)} />
            </li>
            <li :for={{seg, i} <- Enum.with_index(segs)}>
              <.transition_row :if={i > 0} t={Transition.between(Enum.at(segs, i - 1), seg)} />
              <.segment_row seg={seg} playable={playable?(@mix)} recorte={@recorte} />
            </li>
          <% end %>
        </ol>

        <nav
          :if={@mix.segments != []}
          aria-label="Navegação da lista de faixas"
          class="mt-3 flex flex-wrap items-center justify-between gap-2"
        >
          <a
            id="mix-back-to-tracks"
            href="#mix-tracklist-heading"
            class="inline-flex min-h-9 items-center gap-1 text-body text-primary-soft underline"
          >
            <span class="hero-arrow-up size-3.5" aria-hidden="true" /> Início da lista
          </a>
          <a
            :if={timeline_available?(@mix)}
            id="mix-back-to-timeline"
            href="#mix-timeline-heading"
            class="inline-flex min-h-9 items-center gap-1 text-body text-primary-soft underline"
          >
            Linha do tempo
          </a>
        </nav>

        <p
          :if={@mix.status == :ready and @mix.segments == []}
          class="mt-5 text-body-sm text-ink-muted"
        >
          Nenhuma faixa detectada na gravação.
        </p>
      </div>
    </.app_shell>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RecorteDraft">
      export default {
        mounted() {
          this.study = this.el.closest("[data-mix-study]")
          this.guardDraft = (event) => {
            const button = event.target.closest("button[data-recorte-confirm]")
            if (!button) return

            const form = this.el.querySelector("#recorte-form")
            if (!form) return

            // Compare live DOM values, including edits still awaiting a phx-change
            // round trip. The server supplies the initial prefill for each draft.
            const edited = ["range", "artist", "title", "folder"].some((name) => {
              const current = form.elements.namedItem(name)?.value || ""
              const initial = this.el.getAttribute("data-initial-" + name) || ""
              return current !== initial
            })

            if (edited && !window.confirm(button.dataset.recorteConfirm)) {
              event.preventDefault()
              event.stopImmediatePropagation()
            }
          }
          window.addEventListener("click", this.guardDraft, true)
          this.onEscape = (event) => {
            if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return
            event.preventDefault()
            event.stopPropagation()
            // The close button runs the same unsaved-draft confirmation as a click.
            this.el.querySelector("#recorte-close")?.click()
          }
          this.el.addEventListener("keydown", this.onEscape)
          this.revealDraft()
        },
        updated() {
          // Form changes and background ticks must not steal the DJ's focus.
          if (this.draftVersion !== this.el.dataset.draftVersion) this.revealDraft()
        },
        revealDraft() {
          this.draftVersion = this.el.dataset.draftVersion
          this.originId = this.el.dataset.originId
          const version = this.draftVersion
          requestAnimationFrame(() => {
            if (!this.el.isConnected || this.el.dataset.draftVersion !== version) return
            this.el.querySelector("#recorte-title")?.focus({preventScroll: true})
            this.el.scrollIntoView({block: "start", inline: "nearest"})
          })
        },
        destroyed() {
          window.removeEventListener("click", this.guardDraft, true)
          this.el.removeEventListener("keydown", this.onEscape)
          // The draft has been closed or queued. Restore the exact row after
          // LiveView applies the removal (the opener may have been far below).
          requestAnimationFrame(() => {
            if (!this.study?.isConnected || this.study.querySelector("#recorte-editor")) return
            const opener = document.getElementById(this.originId) || this.study.querySelector("#mix-tracklist-heading")
            if (!opener || !this.study.contains(opener)) return
            opener.focus({preventScroll: true})
            opener.scrollIntoView({block: "center", inline: "nearest"})
          })
        },
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RecortePreview">
      // A prévia é a ÚNICA timeline confiável (o player do set escorrega em MP3
      // longo), então marcar início/fim aqui = tempo absoluto exato no arquivo.
      export default {
        mounted() {
          this.player = this.el.querySelector("#recorte-player")
          this.sync()

          this.el.addEventListener("click", (e) => {
            const mark = e.target.closest("[data-mark]")
            if (mark) return this.mark(mark.dataset.mark)
            if (e.target.closest("[data-recorte-copy]")) {
              const status = this.el.querySelector("[data-copy-status]")
              if (!navigator.clipboard) {
                if (status) status.textContent = "Selecione o intervalo para copiar manualmente."
                return
              }
              navigator.clipboard.writeText(this.el.dataset.range || "").then(
                () => { if (status) status.textContent = "Intervalo copiado." },
                () => { if (status) status.textContent = "Selecione o intervalo para copiar manualmente." }
              )
            }
          })

          // I/O mark boundaries only while focus is in the preview.
          this.onKeys = (e) => {
            const t = e.target
            if (e.defaultPrevented || !this.el.contains(t) || t.closest("input, textarea, select, [contenteditable]")) return
            const k = e.key.toLowerCase()
            if (k === "i" || k === "o") {
              this.mark(k === "i" ? "start" : "end")
            } else if (e.key === " " && t === this.el) {
              this.player.paused ? this.player.play().catch(() => {}) : this.player.pause()
            } else {
              return
            }
            e.preventDefault()
          }
          this.el.addEventListener("keydown", this.onKeys)
          this.onPlay = () => document.getElementById("mix-audio")?.pause()
          this.player.addEventListener("play", this.onPlay)
        },

        updated() {
          this.sync()
        },

        destroyed() {
          this.el.removeEventListener("keydown", this.onKeys)
          this.player.removeEventListener("play", this.onPlay)
        },

        mark(field) {
          const at = Number(this.el.dataset.windowStart) + this.player.currentTime * 1000
          this.pushEvent("mark_recorte", {field, ms: Math.round(at)})
        },

        // Trocar o src de um <audio> não recarrega sozinho: sem o load() o
        // player continuaria tocando o trecho anterior depois de um ajuste.
        sync() {
          const src = this.el.dataset.src
          if (this.player && this.player.getAttribute("src") !== src) {
            this.player.setAttribute("src", src)
            this.player.load()
          }
        },
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MixPlayer">
      export default {
        mounted() {
          this.audio = document.getElementById("mix-audio")
          if (!this.audio) return
          const segmentStarts = () => {
            return (this.el.dataset.segmentStarts || "")
              .split(",")
              .map((v) => Number(v))
              .filter((v) => Number.isFinite(v))
              .sort((a, b) => a - b)
          }
          const seekToMs = (ms) => {
            const go = () => { try { this.audio.currentTime = ms / 1000 } catch (_) {} ; this.audio.play().catch(() => {}) }
            if (this.audio.readyState >= 1) go()
            else { this.audio.addEventListener("loadedmetadata", go, { once: true }); this.audio.load() }
          }
          const seekSegment = (direction) => {
            const starts = segmentStarts()
            if (starts.length === 0) return
            const currentMs = this.audio.currentTime * 1000
            if (direction === "next") {
              const next = starts.find((start) => start > currentMs + 750)
              seekToMs(next == null ? starts[starts.length - 1] : next)
            } else {
              const currentIndex = starts.findIndex((start, index) => {
                const next = starts[index + 1]
                return currentMs >= start - 750 && (next == null || currentMs < next - 750)
              })
              const previousIndex = currentIndex <= 0 ? 0 : currentIndex - 1
              seekToMs(starts[previousIndex] || starts[0])
            }
          }
          this.onPrev = (e) => {
            if (!e.target.closest("[data-mix-prev]")) return
            seekSegment("prev")
          }
          this.onNext = (e) => {
            if (!e.target.closest("[data-mix-next]")) return
            seekSegment("next")
          }
          this.onClick = (e) => {
            const btn = e.target.closest("[data-seg-play]")
            if (!btn || !this.audio) return
            const t = Number(btn.dataset.startMs) / 1000
            const go = () => { try { this.audio.currentTime = t } catch (_) {} ; this.audio.play().catch(() => {}) }
            if (this.audio.readyState >= 1) go()
            else { this.audio.addEventListener("loadedmetadata", go, { once: true }); this.audio.load() }
          }
          this.onTime = () => {
            const ms = this.audio.currentTime * 1000
            const timeline = document.getElementById("mix-timeline")
            const cursor = timeline?.querySelector("[data-timeline-cursor]")
            const duration = Number(timeline?.dataset.durationMs)
            if (cursor && duration > 0) cursor.style.left = Math.min(ms / duration * 100, 100) + "%"
            document.querySelectorAll("[data-seg]").forEach((row) => {
              const s = Number(row.dataset.startMs)
              const e = Number(row.dataset.endMs)
              row.classList.toggle("seg-playing", !Number.isNaN(e) && ms >= s && ms < e)
            })
          }
          document.addEventListener("click", this.onClick)
          document.addEventListener("click", this.onPrev)
          document.addEventListener("click", this.onNext)
          this.audio.addEventListener("timeupdate", this.onTime)
          this.onPlay = () => document.getElementById("recorte-player")?.pause()
          this.audio.addEventListener("play", this.onPlay)
        },
        destroyed() {
          document.removeEventListener("click", this.onClick)
          document.removeEventListener("click", this.onPrev)
          document.removeEventListener("click", this.onNext)
          if (this.audio) {
            this.audio.removeEventListener("timeupdate", this.onTime)
            this.audio.removeEventListener("play", this.onPlay)
          }
        },
      }
    </script>
    """
  end

  defp timeline_available?(mix),
    do: is_integer(mix.duration_ms) and mix.duration_ms > 0 and mix.segments != []

  defp recorte_origin(nil), do: "recorte-open-free"
  defp recorte_origin(segment_id), do: "recorte-open-#{segment_id}"

  defp playable?(mix), do: is_nil(mix.audio_deleted_at) and is_binary(mix.audio_path)

  # ── Recortes ────────────────────────────────────────────────────────────────

  defp recorte_prefill(_mix, nil),
    do: %{range: "", artist: "", title: "", folder: nil, mode: "context", segment_id: nil}

  defp recorte_prefill(mix, seg) do
    end_ms = seg.end_ms || min(seg.start_ms + 90_000, mix.duration_ms || seg.start_ms + 90_000)

    %{
      range: range_text(seg.start_ms, end_ms),
      artist: seg.artist || "",
      title: seg.title || "",
      folder: nil,
      mode: "context",
      # Remembered so the cut LINKS BACK: the segment gets matched to the new
      # track (and named by it) instead of staying "não tenho" forever.
      segment_id: seg.id
    }
  end

  # Form params carry the typed fields; mode and segment origin live only in
  # the assign, so they ride along from the previous state.
  defp recorte_from_params(params, previous) do
    %{
      range: params["range"] || "",
      artist: params["artist"] || "",
      title: params["title"] || "",
      folder: if(params["folder"] == "", do: nil, else: params["folder"]),
      mode: previous.mode,
      segment_id: previous.segment_id
    }
  end

  # Moves one end of the range and rewrites the field the DJ reads and pastes.
  defp shift_recorte(socket, field, fun) do
    recorte = socket.assigns.recorte

    case recorte_range(recorte) do
      nil ->
        socket

      {from, to} ->
        {from, to} =
          if field == "start",
            do: {clamp_ms(fun.(from)), to},
            else: {from, clamp_ms(fun.(to))}

        assign(socket, recorte: %{recorte | range: range_text(from, to)})
    end
  end

  defp clamp_ms(ms), do: max(ms, 0)

  defp range_text(from, to), do: "#{format_clock(from)}-#{format_clock(to)}"

  # "3:59:14-4:00:50" pasted in one go — also tolerant of spaces, en/em dashes,
  # arrows and ".." so a copy from anywhere lands without hand-editing.
  defp parse_range(text) do
    parts =
      text
      |> to_string()
      |> String.replace(~r/[–—→>]+|\.\./u, "-")
      |> String.split(~r/\s*-\s*|\s+/, trim: true)

    with [start_text, end_text] <- parts,
         from when is_integer(from) <- parse_clock_ms(start_text),
         to when is_integer(to) <- parse_clock_ms(end_text),
         true <- to > from do
      {from, to}
    else
      _unparseable -> nil
    end
  end

  # "1:23:45", "43:10" or "90" → ms (nil when unparseable; validation catches it).
  defp parse_clock_ms(value) do
    parts = value |> to_string() |> String.trim() |> String.split(":")

    if parts != [] and Enum.all?(parts, &Regex.match?(~r/^\d+$/, &1)) do
      parts
      |> Enum.map(&String.to_integer/1)
      |> Enum.reduce(0, fn part, acc -> acc * 60 + part end)
      |> Kernel.*(1000)
    end
  end

  # The range currently typed, in ms — nil while it isn't a usable pair yet.
  defp recorte_range(recorte), do: parse_range(recorte.range)

  defp recorte_preview_src(mix, recorte, pad_ms) do
    {from, to} = recorte_range(recorte)
    ~p"/sets-online/#{mix.id}/audio?from=#{max(from - pad_ms, 0)}&to=#{to + pad_ms}"
  end

  # Seconds of run-up the context preview adds around the cut.
  defp context_pad_ms, do: 15_000

  defp recorte_pad(%{mode: "exact"}), do: 0
  defp recorte_pad(_recorte), do: context_pad_ms()

  # Where the preview starts in the set — the hook adds the player's own
  # position to this to turn "aqui" into an absolute time.
  defp recorte_window_start(recorte) do
    {from, _to} = recorte_range(recorte)
    max(from - recorte_pad(recorte), 0)
  end

  defp recorte_canonical(recorte) do
    {from, to} = recorte_range(recorte)
    range_text(from, to)
  end

  defp recorte_summary(recorte) do
    {from, to} = recorte_range(recorte)
    "#{format_clock(from)} → #{format_clock(to)} · #{format_clock(to - from)}"
  end

  defp recorte_error(:no_audio),
    do: "O áudio deste set foi limpo — re-baixe o áudio antes de recortar."

  defp recorte_error(:title_required), do: "Dê um título pro recorte."

  defp recorte_error(:invalid_range),
    do: "Tempos inválidos — use h:mm:ss ou mm:ss, fim depois do início."

  defp recorte_error(:too_short), do: "Recorte muito curto — mínimo de 5 segundos."
  defp recorte_error(:too_long), do: "Recorte muito longo — máximo de 15 minutos."
  defp recorte_error(_reason), do: "Não deu pra criar o recorte — veja os logs."

  defp timeline_style(seg, duration) do
    start_pct = min(max(seg.start_ms / duration * 100, 0), 100)
    end_pct = min(max(seg.end_ms / duration * 100, start_pct), 100)
    "left:#{start_pct}%;width:#{end_pct - start_pct}%"
  end

  defp segment_starts(segments) do
    segments
    |> Enum.map(& &1.start_ms)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> Enum.map_join(",", &Integer.to_string/1)
  end

  defp source_label(:manual), do: "manual"
  defp source_label(:chapter), do: "capítulos"
  defp source_label(:image), do: "via OCR"
  defp source_label(:audio), do: "via áudio"
  defp source_label(_), do: nil

  defp name_source_label(:fingerprint), do: "via AudD"
  defp name_source_label(:manual), do: "manual"
  defp name_source_label(_), do: nil

  defp library_coverage([]), do: 0

  defp library_coverage(segs),
    do: round(Enum.count(segs, & &1.matched_track_id) / length(segs) * 100)

  attr :part, :map, default: nil
  attr :count, :integer, required: true

  defp dj_divider(assigns) do
    ~H"""
    <div class="mt-4 mb-2 flex flex-wrap items-center gap-2.5">
      <span class="h-px w-3 bg-white/15"></span>
      <%= if @part do %>
        <form
          id={"dj-rename-#{@part.id}"}
          phx-submit="rename_dj"
          phx-change="rename_dj"
          class="inline-flex items-center gap-1.5"
        >
          <input type="hidden" name="part_id" value={@part.id} />
          <input
            name="name"
            value={@part.dj_name}
            phx-debounce="blur"
            aria-label={"Renomear DJ: #{@part.dj_name || "Sem DJ"}"}
            class="rounded-md bg-primary/10 px-2 py-1 text-body-lg font-semibold text-primary border-0 min-w-0 w-auto max-w-[13rem]"
            placeholder="Sem DJ"
          />
        </form>
        <button
          type="button"
          phx-click="delete_dj"
          phx-value-id={@part.id}
          data-confirm="Apagar esta divisória?"
          title="Apagar divisória"
          aria-label={"Apagar divisória de #{@part.dj_name || "Sem DJ"}"}
          class="rounded px-1 py-0.5 text-[12px] text-ink-faint hover:text-coral"
        >×</button>
      <% else %>
        <span class="inline-flex items-center gap-2 rounded-full bg-primary/15 px-3 py-0.5 text-[13px] font-semibold text-primary">
          Sem DJ
        </span>
      <% end %>
      <span :if={@part} class="font-mono text-[12px] text-ink-secondary">
        {format_clock(@part.start_ms)}–{format_clock(@part.end_ms)}
      </span>
      <span
        :if={@part && source_label(@part.source)}
        class="rounded-full border border-white/10 px-2 py-0.5 text-[11px] text-ink-secondary"
      >
        {source_label(@part.source)}
      </span>
      <span class="text-[11px] text-ink-faint">
        {@count} faixa{if @count != 1, do: "s"}
      </span>
      <span class="h-px flex-1 bg-white/8"></span>
    </div>
    """
  end

  attr :seg, :map, required: true
  attr :playable, :boolean, required: true
  attr :recorte, :map, required: true

  defp segment_row(assigns) do
    ~H"""
    <div
      data-seg
      data-start-ms={@seg.start_ms}
      data-end-ms={@seg.end_ms}
      class="grid min-w-0 gap-2 rounded-lg border border-white/6 bg-surface px-3 py-2.5 xl:grid-cols-[minmax(9rem,auto)_minmax(0,1fr)_auto] xl:items-center"
    >
      <div class="flex flex-wrap items-center gap-2">
        <button
          :if={@playable}
          type="button"
          data-seg-play
          data-start-ms={@seg.start_ms}
          aria-label={"Ouvir a partir de #{format_clock(@seg.start_ms)}"}
          class="inline-flex shrink-0 items-center gap-1 rounded px-1.5 py-1 font-mono text-body-sm text-ink-secondary hover:text-primary"
        >
          <span class="hero-play size-3" aria-hidden="true" />
          {format_clock(@seg.start_ms)}
        </button>
        <span :if={not @playable} class="shrink-0 font-mono text-body-sm text-ink-muted">{format_clock(
          @seg.start_ms
        )}</span>
        <button
          :if={@playable and not named?(@seg)}
          type="button"
          phx-click="recognize_seg"
          phx-value-id={@seg.id}
          disabled={not Beatgrid.Integrations.configured?(:audd)}
          data-confirm="O AudD pode gerar cobrança por consulta. Identificar esta faixa?"
          title="Identificar faixa (AudD)"
          aria-label={"Identificar a faixa em #{format_clock(@seg.start_ms)} (AudD)"}
          class="shrink-0 rounded border border-white/10 bg-white/5 px-1.5 py-0.5 text-[11px] text-ink-muted hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
        >
          Identificar
        </button>
        <span
          :if={name_source_label(@seg.name_source)}
          class="shrink-0 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary/80"
        >
          {name_source_label(@seg.name_source)}
        </span>
      </div>
      <form
        id={"seg-form-#{@seg.id}"}
        phx-submit="save_segment"
        class="flex min-w-0 items-center gap-1.5"
      >
        <input type="hidden" name="segment_id" value={@seg.id} />
        <input
          name="artist"
          value={@seg.artist || ""}
          placeholder="Artista"
          aria-label={"Artista da faixa em #{format_clock(@seg.start_ms)}"}
          class="w-[35%] min-w-0 rounded border border-white/10 bg-transparent px-1.5 py-1.5 text-body text-ink placeholder:text-ink-faint focus:border-primary/50"
        />
        <input
          name="title"
          value={@seg.title || ""}
          placeholder="Título"
          aria-label={"Título da faixa em #{format_clock(@seg.start_ms)}"}
          class="min-w-0 flex-1 rounded border border-white/10 bg-transparent px-1.5 py-1.5 text-body text-ink placeholder:text-ink-faint focus:border-primary/50"
        />
        <button
          type="submit"
          aria-label="Salvar artista e título"
          class="shrink-0 rounded-md border border-white/10 px-2 py-1 text-body-sm text-ink-secondary hover:text-ink"
        >Salvar</button>
      </form>
      <div class="flex flex-wrap items-center gap-2 xl:justify-end">
        <button
          :if={@playable}
          type="button"
          id={recorte_origin(@seg.id)}
          phx-click="open_recorte"
          phx-value-segment={@seg.id}
          aria-controls="recorte-editor"
          aria-expanded={to_string(not is_nil(@recorte) and @recorte.segment_id == @seg.id)}
          title="Recortar este trecho como uma faixa da biblioteca"
          data-recorte-confirm={
            if @recorte, do: "Substituir a edição de recorte pelo trecho desta faixa?"
          }
          aria-label={"Recortar o trecho a partir de #{format_clock(@seg.start_ms)}"}
          class="shrink-0 rounded-md border border-white/10 px-2 py-1 text-body-sm text-ink-secondary hover:text-ink"
        >
          <span class="hero-scissors size-3.5" aria-hidden="true" />
        </button>
        <span
          :if={@seg.bpm_detected}
          class="shrink-0 font-mono text-body-sm tabular-nums text-ink-secondary"
        >{round(@seg.bpm_detected)} BPM</span>
        <.camelot_seal value={@seg.camelot_detected} />
        <.coverage_badge seg={@seg} />
      </div>
    </div>
    """
  end

  attr :t, :map, required: true

  defp transition_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-3 py-0.5 text-body-sm text-ink-muted">
      <span aria-hidden="true">↕</span>
      <span>{camelot_label(@t.camelot)}</span>
      <span :if={@t.bpm_delta && @t.bpm_delta != 0.0}>· {bpm_delta_label(@t.bpm_delta)}</span>
    </div>
    """
  end

  attr :seg, :map, required: true

  defp coverage_badge(assigns) do
    ~H"""
    <.link
      :if={@seg.matched_track_id}
      navigate={~p"/track/#{@seg.matched_track_id}"}
      aria-label={"Abrir faixa da biblioteca em #{format_clock(@seg.start_ms)}"}
      class="shrink-0 rounded-full bg-primary/15 px-2 py-0.5 text-[10px] font-semibold text-primary"
    >
      Abrir faixa
    </.link>
    <a
      :if={is_nil(@seg.matched_track_id) and named?(@seg)}
      href={youtube_search_url(@seg)}
      target="_blank"
      rel="noopener"
      class="shrink-0 rounded-full bg-white/5 px-2 py-0.5 text-[10px] font-semibold text-ink-muted hover:text-ink"
    >
      Buscar no YouTube
    </a>
    <span
      :if={is_nil(@seg.matched_track_id) and not named?(@seg)}
      title={
        if @seg.audd_attempted_at,
          do: "O AudD tentou e não reconheceu esta faixa — preencha artista e título",
          else: "Faixa sem nome — preencha artista e título (ou use o reconhecimento depois)"
      }
      class="shrink-0 rounded-full bg-white/5 px-2 py-0.5 text-[10px] font-semibold text-ink-faint"
    >
      {if @seg.audd_attempted_at, do: "sem match", else: "sem nome"}
    </span>
    """
  end

  defp named?(%{artist: a, title: t}), do: present?(a) or present?(t)
  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  # Are there unnamed segments AudD already tried (no match)? Gates "Tentar tudo de novo".
  defp has_unmatched_attempts?(mix),
    do: Enum.any?(mix.segments, &(not named?(&1) and &1.audd_attempted_at))

  defp progress_label(%{stage: "recognize_done", matched: m, no_match: nm, error: e, total: t}),
    do: "Reconhecimento: #{m} reconhecidas · #{nm} sem match · #{e} erros (de #{t})"

  defp progress_label(%{stage: stage, done: done, total: total})
       when is_integer(done) and is_integer(total),
       do: "#{stage_pt(stage)} #{done}/#{total}"

  defp progress_label(_), do: nil

  defp stage_pt("segments"), do: "Analisando faixa"
  defp stage_pt("boundaries"), do: "Detectando faixas"
  defp stage_pt("dj_vision"), do: "Lendo frame"
  defp stage_pt("dj_audio"), do: "Detectando DJs"
  defp stage_pt("recognize"), do: "Reconhecendo faixa"
  defp stage_pt(_), do: "…"

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil

  defp camelot_label(:perfect), do: "mesmo tom"
  defp camelot_label(:compatible), do: "compatível"
  defp camelot_label(:clash), do: "tom distante"
  defp camelot_label(:unknown), do: "—"

  defp bpm_delta_label(d) when d > 0, do: "+#{d} BPM"
  defp bpm_delta_label(d), do: "#{d} BPM"

  defp youtube_search_url(%{artist: a, title: t}) do
    q = [a, t] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    "https://www.youtube.com/results?search_query=" <> URI.encode(q)
  end

  defp format_clock(nil), do: "—"

  defp format_clock(ms) do
    total = div(ms, 1000)
    h = div(total, 3600)
    m = total |> div(60) |> rem(60)
    s = rem(total, 60)
    if h > 0, do: "#{h}:#{pad(m)}:#{pad(s)}", else: "#{pad(m)}:#{pad(s)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp source_link_label("youtube"), do: "Abrir no YouTube"
  defp source_link_label("soundcloud"), do: "Abrir no SoundCloud"
  defp source_link_label(_), do: "Abrir gravação original"

  defp mix_status_tone(:ready), do: "bg-green/10 text-green"
  defp mix_status_tone(:failed), do: "bg-coral/10 text-coral"
  defp mix_status_tone(_), do: "bg-primary/10 text-primary"

  defp mix_status_label(:downloading), do: "Baixando…"
  defp mix_status_label(:analyzing), do: "Analisando…"
  defp mix_status_label(:ready), do: "Pronto"
  defp mix_status_label(:failed), do: "Falhou"
end
