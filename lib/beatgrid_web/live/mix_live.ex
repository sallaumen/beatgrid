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
           folders: GenreFolders.list()
         )}
    end
  end

  @impl true
  def handle_info(
        {:mix_progress, %{stage: "cut_done", mix_id: id, title: title}},
        %{assigns: %{mix: %{id: id}}} = socket
      ) do
    {:noreply,
     put_flash(
       socket,
       :info,
       "✂ Recorte pronto: “#{title}” já está na Biblioteca (analisando em background)."
     )}
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

    {:noreply, assign(socket, recorte: recorte_prefill(socket.assigns.mix, seg))}
  end

  def handle_event("close_recorte", _params, socket),
    do: {:noreply, assign(socket, recorte: nil)}

  def handle_event("recorte_mode", %{"mode" => mode}, socket) when mode in ~w(context exact),
    do: {:noreply, assign(socket, recorte: %{socket.assigns.recorte | mode: mode})}

  # Every keystroke keeps the assign in sync so the preview players (and the
  # nudge buttons) always point at the range currently on screen.
  def handle_event("recorte_change", params, socket),
    do:
      {:noreply,
       assign(socket, recorte: recorte_from_params(params, socket.assigns.recorte.mode))}

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
      folder_key: if(params["folder"] == "", do: nil, else: params["folder"])
    }

    case Mixes.request_cut(socket.assigns.mix, attrs) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(recorte: nil)
         |> put_flash(:info, "✂ Recorte na fila — a faixa aparece na Biblioteca em instantes.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(recorte: recorte_from_params(params))
         |> put_flash(:error, recorte_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:mixes} socket={@socket}>
      <div class="mx-auto max-w-[1100px] px-6 py-5">
        <.link navigate={~p"/sets-online"} class="text-body-sm text-ink-muted hover:text-ink">
          ← Sets online
        </.link>

        <header class="mt-3 flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
          <div class="min-w-0">
            <h1 class="truncate text-[22px] font-semibold">{@mix.title || @mix.source_url}</h1>
            <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-body-sm text-ink-secondary">
              <span>{@mix.dj || "Unknown DJ"}</span>
              <span class="text-ink-faint">·</span>
              <span>{format_clock(@mix.duration_ms)}</span>
              <span class="text-ink-faint">·</span>
              <a
                href={@mix.source_url}
                target="_blank"
                rel="noopener"
                class="text-primary hover:underline"
              >
                Original link
              </a>
            </div>
            <p
              :if={@mix.description not in [nil, ""]}
              class="mt-2 line-clamp-2 text-caption text-ink-muted"
            >
              {@mix.description}
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-3">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint">
              {mix_status_label(@mix.status)}
            </span>
            <button
              phx-click="reanalyze"
              disabled={not playable?(@mix)}
              title={unless playable?(@mix), do: "Áudio apagado — baixe de novo pra reprocessar"}
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Re-analisar
            </button>
            <button
              phx-click="analyze_all"
              disabled={not playable?(@mix)}
              title={unless playable?(@mix), do: "Áudio apagado — baixe de novo pra reprocessar"}
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Analisar tudo
            </button>
            <button
              :if={playable?(@mix)}
              phx-click="recognize_all"
              disabled={not Beatgrid.Integrations.configured?(:audd)}
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Reconhecer faixas
            </button>
            <button
              :if={playable?(@mix) and has_unmatched_attempts?(@mix)}
              phx-click="recognize_retry_all"
              disabled={not Beatgrid.Integrations.configured?(:audd)}
              title="Re-tentar no AudD as faixas que ainda não casaram"
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Tentar tudo de novo
            </button>
            <.integration_gate :if={playable?(@mix)} key={:audd} />
            <button
              :if={playable?(@mix)}
              phx-click="delete_audio"
              data-confirm="Apagar o áudio deste set? (a análise é preservada)"
              title="Apagar o arquivo de áudio (mantém a análise)"
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-faint hover:bg-coral/10 hover:text-coral"
            >
              Apagar áudio
            </button>
            <button
              :if={@mix.audio_deleted_at && @mix.status != :downloading}
              phx-click="redownload_audio"
              class="rounded-md border border-primary/30 bg-primary/10 px-3 py-1 text-[12px] font-medium text-primary hover:bg-primary/20"
            >
              Baixar áudio de novo
            </button>
          </div>
        </header>

        <%!-- Set summary cards --%>
        <div class="mt-4 grid grid-cols-4 gap-3">
          <div class="rounded-lg border border-white/8 bg-surface px-4 py-3">
            <p class="text-[11px] text-ink-secondary">DJs</p>
            <p class="mt-0.5 text-[22px] font-semibold">
              {if length(@mix.dj_parts) == 0, do: "—", else: length(@mix.dj_parts)}
            </p>
          </div>
          <div class="rounded-lg border border-white/8 bg-surface px-4 py-3">
            <p class="text-[11px] text-ink-secondary">Faixas</p>
            <p class="mt-0.5 text-[22px] font-semibold">{length(@mix.segments)}</p>
          </div>
          <div class="rounded-lg border border-white/8 bg-surface px-4 py-3">
            <p class="text-[11px] text-ink-secondary">Duração</p>
            <p class="mt-0.5 text-[22px] font-semibold">{format_clock(@mix.duration_ms)}</p>
          </div>
          <div class="rounded-lg border border-white/8 bg-surface px-4 py-3">
            <p class="text-[11px] text-ink-secondary">Na biblioteca</p>
            <p class="mt-0.5 text-[22px] font-semibold">{library_coverage(@mix.segments)}%</p>
          </div>
        </div>

        <%!-- Audio-deleted notice --%>
        <p
          :if={@mix.audio_deleted_at}
          class="mt-3 text-body-sm text-ink-muted"
        >
          Áudio apagado (análise preservada).
        </p>

        <div
          :if={playable?(@mix)}
          id="mix-player"
          phx-hook=".MixPlayer"
          data-segment-starts={segment_starts(@mix.segments)}
          class="sticky top-0 z-10 mt-3 rounded-lg border border-white/8 bg-surface/95 px-3 py-2 backdrop-blur"
        >
          <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
            <div class="flex items-center gap-2">
              <button
                type="button"
                data-mix-prev
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-semibold text-ink-secondary hover:bg-white/10 hover:text-ink"
              >
                Previous track
              </button>
              <button
                type="button"
                data-mix-next
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-semibold text-ink-secondary hover:bg-white/10 hover:text-ink"
              >
                Next track
              </button>
            </div>
            <span class="text-caption text-ink-faint">
              {length(@mix.segments)} detected tracks
            </span>
          </div>
          <audio
            id="mix-audio"
            controls
            preload="metadata"
            src={~p"/sets-online/#{@mix.id}/audio"}
            class="w-full"
          />
        </div>

        <p :if={@mix.status == :analyzing} class="mt-4 text-body-sm text-ink-muted">
          Analisando o set… as faixas aparecem quando terminar.
        </p>
        <p :if={@progress} class="mt-1 text-body-sm text-ink-muted font-mono">
          {@progress}
        </p>
        <p :if={@mix.status == :failed} class="mt-4 text-body-sm text-coral">
          A análise falhou. Tente "Re-analisar".
        </p>

        <%!-- DJ panel --%>
        <details class="mt-5 rounded-lg border border-white/8 bg-surface">
          <summary class="cursor-pointer select-none px-4 py-2 text-body-sm font-medium text-ink-secondary hover:text-ink">
            DJs
          </summary>
          <div class="border-t border-white/8 px-4 py-3 space-y-3">
            <form id="dj-manual-form" phx-submit="dj_manual" class="space-y-2">
              <label class="block text-[11px] uppercase tracking-wider text-ink-faint">
                Timestamps manuais (ex: 0:00 DJ Nome)
              </label>
              <textarea
                name="timestamps"
                rows="4"
                class="w-full rounded border border-white/10 bg-transparent px-2 py-1.5 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary/50 focus:outline-none font-mono"
                placeholder="0:00 DJ A\n30:00 DJ B"
              ></textarea>
              <button
                type="submit"
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
              >
                Aplicar timestamps
              </button>
            </form>
            <div class="flex flex-wrap gap-2">
              <button
                phx-click="dj_chapters"
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
              >
                Usar capítulos como DJs
              </button>
              <button
                phx-click="dj_image"
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
              >
                Detectar por imagem
              </button>
              <button
                phx-click="dj_audio"
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
              >
                Detectar por áudio
              </button>
              <button
                phx-click="dj_clear"
                class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
              >
                Limpar divisão por DJ
              </button>
            </div>
          </div>
        </details>

        <%!-- Segment timeline --%>
        <div :if={playable?(@mix) and is_nil(@recorte)} class="mt-5">
          <button
            type="button"
            phx-click="open_recorte"
            class="rounded-md border border-white/10 px-3 py-1.5 text-body-sm font-semibold text-ink-secondary hover:text-ink"
          >
            ✂ Recortar trecho
          </button>
        </div>

        <div :if={@recorte} class="mt-5 rounded-xl border border-primary/25 bg-surface p-4">
          <div class="flex items-center justify-between">
            <h3 class="text-body-sm font-semibold">✂ Novo recorte</h3>
            <button
              type="button"
              phx-click="close_recorte"
              aria-label="Fechar"
              class="text-ink-faint hover:text-ink"
            >
              ✕
            </button>
          </div>
          <p class="mt-1 text-caption text-ink-muted">
            O trecho vira uma faixa de verdade na Biblioteca — MP3 próprio, marcado como
            recorte e ligado a este set.
          </p>

          <div class="mt-4 space-y-4">
            <section>
              <div class="flex items-baseline gap-2">
                <span class="text-caption font-bold text-primary">1</span>
                <h4 class="text-body-sm font-semibold">Trecho</h4>
                <span class="text-caption text-ink-faint">cole início-fim de uma vez</span>
              </div>

              <div class="mt-1.5 flex flex-wrap items-center gap-2">
                <input
                  form="recorte-form"
                  name="range"
                  value={@recorte.range}
                  aria-label="Trecho do recorte (início-fim)"
                  placeholder="3:59:14-4:00:50"
                  class="h-10 w-56 rounded-lg border border-white/12 bg-input px-3 font-mono text-body text-ink placeholder:text-ink-faint focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/40"
                />
                <span
                  :if={recorte_range(@recorte)}
                  class="font-mono text-body-sm tabular-nums text-ink-secondary"
                >
                  {recorte_summary(@recorte)}
                </span>
                <button
                  :if={recorte_range(@recorte)}
                  type="button"
                  data-recorte-copy
                  form="recorte-form"
                  title="Copiar o trecho"
                  class="h-8 rounded-md border border-white/12 px-2.5 text-caption text-ink-muted hover:border-white/25 hover:text-ink focus:outline-none focus:ring-2 focus:ring-primary/40"
                >
                  ⧉ copiar
                </button>
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
                    :for={delta <- [-5000, 5000]}
                    type="button"
                    phx-click="nudge_recorte"
                    phx-value-field={field}
                    phx-value-delta={delta}
                    class="h-8 w-11 rounded-md border border-white/12 font-mono text-caption text-ink-secondary hover:border-primary/50 hover:text-ink focus:outline-none focus:ring-2 focus:ring-primary/40"
                  >
                    {if delta < 0, do: "−5s", else: "+5s"}
                  </button>
                </div>
              </div>
            </section>

            <section
              :if={recorte_range(@recorte)}
              id="recorte-preview"
              phx-hook=".RecortePreview"
              data-window-start={recorte_window_start(@recorte)}
              data-range={recorte_canonical(@recorte)}
              data-src={recorte_preview_src(@mix, @recorte, recorte_pad(@recorte))}
            >
              <div class="flex flex-wrap items-baseline gap-2">
                <span class="text-caption font-bold text-primary">2</span>
                <h4 class="text-body-sm font-semibold">Ouça e marque</h4>
                <div class="ml-auto flex overflow-hidden rounded-md border border-white/12">
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
                      "px-2.5 py-1 text-caption focus:outline-none focus:ring-2 focus:ring-primary/40",
                      (@recorte.mode == mode && "bg-primary/20 text-primary") ||
                        "text-ink-muted hover:text-ink"
                    ]}
                  >
                    {label}
                  </button>
                </div>
              </div>

              <audio id="recorte-player" controls preload="metadata" class="mt-1.5 w-full" />

              <div class="mt-2 flex flex-col gap-2 sm:flex-row">
                <button
                  type="button"
                  data-mark="start"
                  title="Onde a prévia está agora vira o início do recorte (tecla I)"
                  class="flex h-11 flex-1 items-center justify-center gap-2 rounded-lg border border-primary/50 bg-primary/10 text-body-sm font-semibold text-primary hover:bg-primary/20 focus:outline-none focus:ring-2 focus:ring-primary/50"
                >
                  ⟵ marcar início <kbd class="rounded bg-black/30 px-1 font-mono text-[10px]">I</kbd>
                </button>
                <button
                  type="button"
                  data-mark="end"
                  title="Onde a prévia está agora vira o fim do recorte (tecla O)"
                  class="flex h-11 flex-1 items-center justify-center gap-2 rounded-lg border border-primary/50 bg-primary/10 text-body-sm font-semibold text-primary hover:bg-primary/20 focus:outline-none focus:ring-2 focus:ring-primary/50"
                >
                  marcar fim <kbd class="rounded bg-black/30 px-1 font-mono text-[10px]">O</kbd> ⟶
                </button>
              </div>

              <p class="mt-1.5 text-caption text-ink-faint">
                Esta prévia é cortada no servidor: a posição dela é exata (o relógio do player
                do set inteiro escorrega em MP3 de horas). Atalhos: <b>espaço</b>
                toca/pausa, <b>I</b>
                marca início, <b>O</b>
                marca fim.
              </p>
            </section>

            <section>
              <div class="flex items-baseline gap-2">
                <span class="text-caption font-bold text-primary">3</span>
                <h4 class="text-body-sm font-semibold">Nome e destino</h4>
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
                    class="mt-0.5 h-10 w-full rounded-lg border border-white/12 bg-input px-3 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/40"
                  />
                </label>
                <label class="text-caption text-ink-muted sm:col-span-4">
                  Artista <span class="text-ink-faint">(opcional)</span>
                  <input
                    name="artist"
                    value={@recorte.artist}
                    placeholder="Os 3 do Nordeste"
                    class="mt-0.5 h-10 w-full rounded-lg border border-white/12 bg-input px-3 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/40"
                  />
                </label>
                <label class="text-caption text-ink-muted sm:col-span-2">
                  Pasta
                  <select
                    name="folder"
                    class="mt-0.5 h-10 w-full rounded-lg border border-white/12 bg-input px-2 text-body-sm text-ink focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/40"
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
                  class="h-10 rounded-lg bg-primary px-4 text-body-sm font-semibold text-white hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-primary/50 disabled:opacity-40 sm:col-span-2"
                >
                  ✂ Criar
                </button>
              </form>
            </section>
          </div>
        </div>

        <ol :if={@mix.segments != []} class="mt-5 space-y-1">
          <%= for {part, segs} <- Mixes.group_by_dj(@mix.segments, @mix.dj_parts) do %>
            <li :if={@mix.dj_parts != []} class="list-none">
              <.dj_divider part={part} count={length(segs)} />
            </li>
            <li :for={{seg, i} <- Enum.with_index(segs)}>
              <.transition_row :if={i > 0} t={Transition.between(Enum.at(segs, i - 1), seg)} />
              <.segment_row seg={seg} playable={playable?(@mix)} />
            </li>
          <% end %>
        </ol>

        <p
          :if={@mix.status == :ready and @mix.segments == []}
          class="mt-5 text-body-sm text-ink-muted"
        >
          Nenhum segmento — o set não tinha tracklist e o áudio não rendeu fronteiras.
        </p>
      </div>
    </.app_shell>
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
              navigator.clipboard.writeText(this.el.dataset.range || "")
            }
          })

          // Atalhos de editor: I/O marcam entrada e saída, espaço toca.
          this.onKeys = (e) => {
            const t = e.target
            if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT")) return
            const k = e.key.toLowerCase()
            if (k === "i" || k === "o") {
              this.mark(k === "i" ? "start" : "end")
            } else if (e.key === " ") {
              this.player.paused ? this.player.play().catch(() => {}) : this.player.pause()
            } else {
              return
            }
            e.preventDefault()
          }
          window.addEventListener("keydown", this.onKeys)
        },

        updated() {
          this.sync()
        },

        destroyed() {
          window.removeEventListener("keydown", this.onKeys)
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
        },
        destroyed() {
          document.removeEventListener("click", this.onClick)
          document.removeEventListener("click", this.onPrev)
          document.removeEventListener("click", this.onNext)
          if (this.audio) this.audio.removeEventListener("timeupdate", this.onTime)
        },
      }
    </script>
    """
  end

  defp playable?(mix), do: is_nil(mix.audio_deleted_at) and is_binary(mix.audio_path)

  # ── Recortes ────────────────────────────────────────────────────────────────

  defp recorte_prefill(_mix, nil),
    do: %{range: "", artist: "", title: "", folder: nil, mode: "context"}

  defp recorte_prefill(mix, seg) do
    end_ms = seg.end_ms || min(seg.start_ms + 90_000, mix.duration_ms || seg.start_ms + 90_000)

    %{
      range: range_text(seg.start_ms, end_ms),
      artist: seg.artist || "",
      title: seg.title || "",
      folder: nil,
      mode: "context"
    }
  end

  defp recorte_from_params(params, mode \\ "context") do
    %{
      range: params["range"] || "",
      artist: params["artist"] || "",
      title: params["title"] || "",
      folder: if(params["folder"] == "", do: nil, else: params["folder"]),
      mode: mode
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

  defp recorte_length_label(recorte) do
    {from, to} = recorte_range(recorte)
    format_clock(to - from)
  end

  defp recorte_error(:no_audio),
    do: "O áudio deste set foi limpo — re-baixe o áudio antes de recortar."

  defp recorte_error(:title_required), do: "Dê um título pro recorte."

  defp recorte_error(:invalid_range),
    do: "Tempos inválidos — use h:mm:ss ou mm:ss, fim depois do início."

  defp recorte_error(:too_short), do: "Recorte muito curto — mínimo de 5 segundos."
  defp recorte_error(:too_long), do: "Recorte muito longo — máximo de 15 minutos."
  defp recorte_error(_reason), do: "Não deu pra criar o recorte — veja os logs."

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
    <div class="flex items-center gap-2.5 mt-4 mb-2">
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
            class="rounded-full bg-primary/15 px-3 py-0.5 text-[13px] font-semibold text-primary border-0 outline-none focus:ring-1 focus:ring-primary/50 min-w-0 w-auto"
            placeholder="Sem DJ"
          />
        </form>
        <button
          type="button"
          phx-click="delete_dj"
          phx-value-id={@part.id}
          data-confirm="Apagar esta divisória?"
          title="Apagar divisória"
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

  defp segment_row(assigns) do
    ~H"""
    <div
      data-seg
      data-start-ms={@seg.start_ms}
      data-end-ms={@seg.end_ms}
      class="flex items-center gap-3 rounded-lg border border-white/6 bg-surface px-3 py-2"
    >
      <button
        :if={@playable}
        type="button"
        data-seg-play
        data-start-ms={@seg.start_ms}
        title="Ouvir a partir daqui"
        class="shrink-0 rounded px-1.5 py-0.5 text-[12px] text-ink-muted hover:text-ink"
      >
        ▶
      </button>
      <button
        :if={@playable}
        type="button"
        data-seg-play
        data-start-ms={@seg.start_ms}
        title="Ouvir a partir daqui"
        class="w-12 shrink-0 rounded px-1 py-0.5 font-mono text-body-sm text-ink-muted hover:text-ink"
      >{format_clock(@seg.start_ms)}</button>
      <span :if={not @playable} class="w-12 shrink-0 font-mono text-body-sm text-ink-muted">{format_clock(
        @seg.start_ms
      )}</span>
      <button
        :if={@playable and not named?(@seg)}
        type="button"
        phx-click="recognize_seg"
        phx-value-id={@seg.id}
        disabled={not Beatgrid.Integrations.configured?(:audd)}
        title="Identificar faixa (AudD)"
        class="shrink-0 rounded border border-white/10 bg-white/5 px-1.5 py-0.5 text-[11px] text-ink-muted hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
      >
        ?
      </button>
      <span
        :if={name_source_label(@seg.name_source)}
        class="shrink-0 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary/80"
      >
        {name_source_label(@seg.name_source)}
      </span>
      <form
        id={"seg-form-#{@seg.id}"}
        phx-submit="save_segment"
        class="min-w-0 flex-1 flex items-center gap-2"
      >
        <input type="hidden" name="segment_id" value={@seg.id} />
        <input
          name="artist"
          value={@seg.artist || ""}
          placeholder="Artista"
          class="w-32 shrink-0 rounded border border-white/10 bg-transparent px-1.5 py-0.5 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary/50 focus:outline-none"
        />
        <input
          name="title"
          value={@seg.title || ""}
          placeholder="Título"
          class="min-w-0 flex-1 rounded border border-white/10 bg-transparent px-1.5 py-0.5 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary/50 focus:outline-none"
        />
        <button
          type="submit"
          aria-label="Salvar título"
          class="shrink-0 rounded px-2 py-0.5 text-[11px] text-ink-faint hover:text-ink"
        >✓</button>
      </form>
      <button
        :if={@playable}
        type="button"
        phx-click="open_recorte"
        phx-value-segment={@seg.id}
        title="Recortar este trecho como uma faixa da biblioteca"
        class="shrink-0 rounded px-1 py-0.5 text-[12px] text-ink-muted hover:text-ink"
      >
        ✂
      </button>
      <span :if={@seg.bpm_detected} class="shrink-0 text-body-sm text-primary">{round(
        @seg.bpm_detected
      )} BPM</span>
      <.camelot_seal value={@seg.camelot_detected} />
      <.coverage_badge seg={@seg} />
    </div>
    """
  end

  attr :t, :map, required: true

  defp transition_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-3 py-0.5 text-[11px] text-ink-faint">
      <span>↕</span>
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
      class="shrink-0 rounded-full bg-primary/15 px-2 py-0.5 text-[10px] font-semibold text-primary"
    >
      ✓ tenho
    </.link>
    <a
      :if={is_nil(@seg.matched_track_id) and named?(@seg)}
      href={youtube_search_url(@seg)}
      target="_blank"
      rel="noopener"
      class="shrink-0 rounded-full bg-white/5 px-2 py-0.5 text-[10px] font-semibold text-ink-muted hover:text-ink"
    >
      não tenho ↗
    </a>
    <span
      :if={is_nil(@seg.matched_track_id) and not named?(@seg)}
      title={
        if @seg.audd_attempted_at,
          do: "O AudD tentou e não reconheceu esta faixa — preencha à mão acima",
          else: "Faixa sem nome — preencha artista/título acima (ou use o reconhecimento depois)"
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

  defp mix_status_label(:downloading), do: "Baixando…"
  defp mix_status_label(:analyzing), do: "Analisando…"
  defp mix_status_label(:ready), do: "Pronto"
  defp mix_status_label(:failed), do: "Falhou"
end
