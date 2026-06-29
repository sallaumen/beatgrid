defmodule BeatgridWeb.MixLive do
  @moduledoc "Curadoria: study one recorded online set — segment timeline + transition map."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

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
        {:ok, assign(socket, page_title: mix.title || "Set", mix: mix, progress: nil)}
    end
  end

  @impl true
  def handle_info({:mix_progress, %{mix_id: id} = payload}, %{assigns: %{mix: %{id: id}}} = socket) do
    {:noreply, assign(socket, mix: Mixes.get_with_dj_parts(id), progress: progress_label(payload))}
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

  def handle_event("keep_audio", _params, socket) do
    {:ok, _} = Mixes.cancel_cleanup(socket.assigns.mix)

    {:noreply,
     socket
     |> put_flash(:info, "Arquivo mantido — não será apagado.")
     |> assign(mix: Mixes.get_with_dj_parts(socket.assigns.mix.id))}
  end

  def handle_event("reanalyze", _params, socket) do
    mix = socket.assigns.mix
    {:ok, _} = Mixes.set_status(mix, :analyzing)
    {:ok, _} = Oban.insert(MixAnalyzeWorker.new(%{mix_id: mix.id}))
    {:noreply, assign(socket, mix: Mixes.get_with_dj_parts(mix.id))}
  end

  def handle_event("recognize_all", _params, socket) do
    case Mixes.recognize_unnamed(socket.assigns.mix) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Reconhecimento iniciado — atualiza quando terminar.")}

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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, dj_error_message(reason))}
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

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:mixes} socket={@socket}>
      <div class="mx-auto max-w-[1100px] px-6 py-5">
        <.link navigate={~p"/sets-online"} class="text-body-sm text-ink-muted hover:text-ink">
          ← Sets online
        </.link>

        <header class="mt-3 flex items-baseline justify-between gap-4">
          <div class="min-w-0">
            <h1 class="truncate text-[22px] font-semibold">{@mix.title || @mix.source_url}</h1>
            <p class="text-body-sm text-ink-secondary">
              {@mix.dj || "—"} · {format_clock(@mix.duration_ms)}
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-3">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint">
              {mix_status_label(@mix.status)}
            </span>
            <button
              phx-click="reanalyze"
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink"
            >
              Re-analisar
            </button>
            <button
              :if={playable?(@mix)}
              phx-click="recognize_all"
              disabled={not Beatgrid.Integrations.configured?(:audd)}
              class="rounded-md border border-white/10 bg-white/5 px-3 py-1 text-[12px] font-medium text-ink-muted hover:bg-white/10 hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Reconhecer faixas
            </button>
            <.integration_gate :if={playable?(@mix)} key={:audd} />
          </div>
        </header>

        <%!-- Cleanup / audio-deleted banner --%>
        <div
          :if={@mix.cleanup_job_id && is_nil(@mix.audio_deleted_at)}
          class="mt-3 flex items-center gap-3 rounded-lg border border-amber-400/20 bg-amber-400/5 px-4 py-2 text-body-sm text-amber-300"
        >
          <span>🗑 o áudio será apagado ~24h após a análise</span>
          <button
            phx-click="keep_audio"
            class="ml-auto rounded-md border border-amber-400/30 bg-amber-400/10 px-3 py-1 text-[12px] font-medium hover:bg-amber-400/20"
          >
            Manter arquivo
          </button>
        </div>
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
          class="sticky top-0 z-10 mt-3 rounded-lg border border-white/8 bg-surface/95 backdrop-blur px-3 py-2"
        >
          <audio id="mix-audio" controls preload="metadata" src={~p"/sets-online/#{@mix.id}/audio"} class="w-full" />
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
                placeholder={"0:00 DJ A\n30:00 DJ B"}
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
        <%= if @mix.dj_parts != [] do %>
          <div class="mt-5 space-y-4">
            <%= for {part, segs} <- Mixes.group_by_dj(@mix.segments, @mix.dj_parts) do %>
              <details open class="rounded-lg border border-white/8">
                <summary class="cursor-pointer select-none px-4 py-2 flex items-center gap-3">
                  <span class="font-semibold text-[14px] text-ink">
                    {(part && part.dj_name) || "Sem DJ"}
                  </span>
                  <%= if part do %>
                    <span class="text-body-sm text-ink-muted font-mono">
                      {format_clock(part.start_ms)}–{format_clock(part.end_ms)}
                    </span>
                  <% end %>
                  <span class="text-[11px] text-ink-faint ml-auto">
                    {length(segs)} faixa{if length(segs) != 1, do: "s"}
                  </span>
                </summary>
                <ol class="border-t border-white/8 space-y-1 px-2 py-2">
                  <li :for={{seg, i} <- Enum.with_index(segs)}>
                    <.transition_row
                      :if={i > 0}
                      t={Transition.between(Enum.at(segs, i - 1), seg)}
                    />
                    <.segment_row seg={seg} playable={playable?(@mix)} />
                  </li>
                </ol>
              </details>
            <% end %>
          </div>
        <% else %>
          <ol :if={@mix.segments != []} class="mt-5 space-y-1">
            <li :for={{seg, i} <- Enum.with_index(@mix.segments)}>
              <.transition_row :if={i > 0} t={Transition.between(Enum.at(@mix.segments, i - 1), seg)} />
              <.segment_row seg={seg} playable={playable?(@mix)} />
            </li>
          </ol>
        <% end %>

        <p
          :if={@mix.status == :ready and @mix.segments == []}
          class="mt-5 text-body-sm text-ink-muted"
        >
          Nenhum segmento — o set não tinha tracklist e o áudio não rendeu fronteiras.
        </p>
      </div>
    </.app_shell>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MixPlayer">
      export default {
        mounted() {
          this.audio = document.getElementById("mix-audio")
          if (!this.audio) return
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
          this.audio.addEventListener("timeupdate", this.onTime)
        },
        destroyed() {
          document.removeEventListener("click", this.onClick)
          if (this.audio) this.audio.removeEventListener("timeupdate", this.onTime)
        },
      }
    </script>
    """
  end

  defp playable?(mix), do: is_nil(mix.audio_deleted_at) and is_binary(mix.audio_path)

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
        class="w-12 shrink-0 font-mono text-body-sm text-ink-muted hover:text-ink"
      >{format_clock(@seg.start_ms)}</button>
      <span :if={not @playable} class="w-12 shrink-0 font-mono text-body-sm text-ink-muted">{format_clock(@seg.start_ms)}</span>
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
        :if={@seg.name_source == :fingerprint}
        class="shrink-0 rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-semibold text-primary/80"
      >
        via AudD
      </span>
      <form id={"seg-form-#{@seg.id}"} phx-submit="save_segment" class="min-w-0 flex-1 flex items-center gap-2">
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
        <button type="submit" class="shrink-0 rounded px-2 py-0.5 text-[11px] text-ink-faint hover:text-ink">✓</button>
      </form>
      <span :if={@seg.bpm_detected} class="shrink-0 text-body-sm text-primary">{round(@seg.bpm_detected)} BPM</span>
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
      title="Faixa sem nome — preencha artista/título acima (ou use o reconhecimento depois)"
      class="shrink-0 rounded-full bg-white/5 px-2 py-0.5 text-[10px] font-semibold text-ink-faint"
    >
      sem nome
    </span>
    """
  end

  defp named?(%{artist: a, title: t}), do: present?(a) or present?(t)
  defp present?(s), do: is_binary(s) and String.trim(s) != ""

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

  defp dj_error_message(:no_chapters), do: "Esse set não tem capítulos."
  defp dj_error_message(:manual_present), do: "Limpe a divisão manual primeiro."
  defp dj_error_message(_), do: "Erro ao aplicar divisão por DJ."

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
