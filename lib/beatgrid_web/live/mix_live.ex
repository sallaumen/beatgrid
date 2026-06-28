defmodule BeatgridWeb.MixLive do
  @moduledoc "Curadoria: study one recorded online set — segment timeline + transition map."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Mixes
  alias Beatgrid.Mixes.Transition
  alias Beatgrid.Workers.MixAnalyzeWorker

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Mixes.get_with_segments(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "Set não encontrado.") |> push_navigate(to: ~p"/sets-online")}

      mix ->
        if connected?(socket), do: Mixes.subscribe()
        {:ok, assign(socket, page_title: mix.title || "Set", mix: mix)}
    end
  end

  @impl true
  def handle_info({:mix_progress, %{mix_id: id}}, %{assigns: %{mix: %{id: id}}} = socket) do
    {:noreply, assign(socket, mix: Mixes.get_with_segments(id))}
  end

  def handle_info({:mix_progress, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "save_segment",
        %{"segment_id" => id, "artist" => artist, "title" => title},
        socket
      ) do
    seg = Enum.find(socket.assigns.mix.segments, &(&1.id == id))
    match = Mixes.match_track(artist, title)

    {:ok, _} =
      Mixes.update_segment(seg, %{
        artist: blank_to_nil(artist),
        title: blank_to_nil(title),
        name_source: :manual,
        matched_track_id: match && match.track_id,
        match_confidence: match && match.confidence
      })

    {:noreply, assign(socket, mix: Mixes.get_with_segments(socket.assigns.mix.id))}
  end

  def handle_event("keep_audio", _params, socket) do
    {:ok, _} = Mixes.cancel_cleanup(socket.assigns.mix)

    {:noreply,
     socket
     |> put_flash(:info, "Arquivo mantido — não será apagado.")
     |> assign(mix: Mixes.get_with_segments(socket.assigns.mix.id))}
  end

  def handle_event("reanalyze", _params, socket) do
    mix = socket.assigns.mix
    {:ok, _} = Mixes.set_status(mix, :analyzing)
    {:ok, _} = Oban.insert(MixAnalyzeWorker.new(%{mix_id: mix.id}))
    {:noreply, assign(socket, mix: Mixes.get_with_segments(mix.id))}
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

        <p :if={@mix.status == :analyzing} class="mt-4 text-body-sm text-ink-muted">
          Analisando o set… as faixas aparecem quando terminar.
        </p>
        <p :if={@mix.status == :failed} class="mt-4 text-body-sm text-coral">
          A análise falhou. Tente "Re-analisar".
        </p>

        <ol :if={@mix.segments != []} class="mt-5 space-y-1">
          <li :for={{seg, i} <- Enum.with_index(@mix.segments)}>
            <.transition_row :if={i > 0} t={Transition.between(Enum.at(@mix.segments, i - 1), seg)} />
            <div class="flex items-center gap-3 rounded-lg border border-white/6 bg-surface px-3 py-2">
              <span class="w-12 shrink-0 font-mono text-body-sm text-ink-muted">{format_clock(
                seg.start_ms
              )}</span>
              <form
                id={"seg-form-#{seg.id}"}
                phx-submit="save_segment"
                class="min-w-0 flex-1 flex items-center gap-2"
              >
                <input type="hidden" name="segment_id" value={seg.id} />
                <input
                  name="artist"
                  value={seg.artist || ""}
                  placeholder="Artista"
                  class="w-32 shrink-0 rounded border border-white/10 bg-transparent px-1.5 py-0.5 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary/50 focus:outline-none"
                />
                <input
                  name="title"
                  value={seg.title || ""}
                  placeholder="Título"
                  class="min-w-0 flex-1 rounded border border-white/10 bg-transparent px-1.5 py-0.5 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary/50 focus:outline-none"
                />
                <button
                  type="submit"
                  class="shrink-0 rounded px-2 py-0.5 text-[11px] text-ink-faint hover:text-ink"
                >
                  ✓
                </button>
              </form>
              <span :if={seg.bpm_detected} class="shrink-0 text-body-sm text-primary">{round(
                seg.bpm_detected
              )} BPM</span>
              <.camelot_seal value={seg.camelot_detected} />
              <.coverage_badge seg={seg} />
            </div>
          </li>
        </ol>

        <p
          :if={@mix.status == :ready and @mix.segments == []}
          class="mt-5 text-body-sm text-ink-muted"
        >
          Nenhum segmento — o set não tinha tracklist e o áudio não rendeu fronteiras.
        </p>
      </div>
    </.app_shell>
    """
  end

  attr :t, :map, required: true

  defp transition_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-3 py-0.5 text-[11px] text-ink-faint">
      <span>↕</span>
      <span>{camelot_label(@t.camelot)}</span>
      <span :if={@t.bpm_delta}>· {bpm_delta_label(@t.bpm_delta)}</span>
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
      :if={is_nil(@seg.matched_track_id)}
      href={youtube_search_url(@seg)}
      target="_blank"
      rel="noopener"
      class="shrink-0 rounded-full bg-white/5 px-2 py-0.5 text-[10px] font-semibold text-ink-muted hover:text-ink"
    >
      não tenho ↗
    </a>
    """
  end

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
    "#{pad(div(total, 60))}:#{pad(rem(total, 60))}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp mix_status_label(:downloading), do: "Baixando…"
  defp mix_status_label(:analyzing), do: "Analisando…"
  defp mix_status_label(:ready), do: "Pronto"
  defp mix_status_label(:failed), do: "Falhou"
end
