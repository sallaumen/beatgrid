defmodule BeatgridWeb.TrackLive do
  @moduledoc "Detalhe da faixa — metadata, rating, tags, note, harmonic next track."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Analysis
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Mixing
  alias Beatgrid.Sets
  alias Phoenix.LiveView.JS

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Tracks.get_with_song(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Faixa não encontrada.") |> push_navigate(to: ~p"/")}

      track ->
        {:ok,
         socket
         |> assign(
           track: track,
           next: Mixing.suggest_next(track, limit: 8),
           tag_draft: "",
           analyzing?: false,
           page_title: title(track)
         )
         |> maybe_auto_analyze()}
    end
  end

  # Auto-run local analysis the first time a track is opened without it (connected
  # mount only, so it runs once over the websocket — not during the dead render).
  defp maybe_auto_analyze(socket) do
    track = socket.assigns.track

    if connected?(socket) and is_nil(track.analyzed_at) do
      socket
      |> assign(analyzing?: true)
      |> start_async(:analyze, fn -> Analysis.analyze_track(track) end)
    else
      socket
    end
  end

  @impl true
  def handle_event("set_rating", %{"n" => n}, socket) do
    {:noreply, save(socket, %{rating: String.to_integer(n)})}
  end

  def handle_event("add_tag", %{"tag" => tag}, socket) do
    tag = String.trim(tag)

    if tag == "" do
      {:noreply, socket}
    else
      tags = Enum.uniq((socket.assigns.track.tags || []) ++ [tag])
      {:noreply, socket |> save(%{tags: tags}) |> assign(tag_draft: "")}
    end
  end

  def handle_event("remove_tag", %{"tag" => tag}, socket) do
    {:noreply, save(socket, %{tags: (socket.assigns.track.tags || []) -- [tag]})}
  end

  def handle_event("save_note", %{"note" => note}, socket) do
    {:noreply, save(socket, %{personal_note: note})}
  end

  def handle_event("start_set", _params, socket) do
    track = socket.assigns.track
    {:ok, set} = Sets.create("Set: #{title(track)}")
    Sets.append(set, track)
    {:noreply, push_navigate(socket, to: ~p"/set")}
  end

  def handle_event("add_marker", %{"ms" => ms}, socket) do
    {:ok, _} = Tracks.add_marker(socket.assigns.track, trunc(ms))
    {:noreply, socket |> reload() |> push_markers()}
  end

  def handle_event("remove_marker", %{"ms" => ms}, socket) do
    {:ok, _} = Tracks.remove_marker(socket.assigns.track, String.to_integer(ms))
    {:noreply, socket |> reload() |> push_markers()}
  end

  def handle_event("reanalyze", _params, socket) do
    track = socket.assigns.track

    {:noreply,
     socket
     |> assign(analyzing?: true)
     |> start_async(:analyze, fn -> Analysis.analyze_track(track) end)}
  end

  @impl true
  def handle_async(:analyze, {:ok, {:ok, _track}}, socket) do
    {:noreply, socket |> assign(analyzing?: false) |> reload()}
  end

  def handle_async(:analyze, _result, socket) do
    {:noreply, assign(socket, analyzing?: false)}
  end

  defp save(socket, attrs) do
    {:ok, _} = Tracks.update(socket.assigns.track, attrs)
    reload(socket)
  end

  defp reload(socket),
    do: assign(socket, track: Tracks.get_with_song(socket.assigns.track.id))

  defp push_markers(socket),
    do: push_event(socket, "markers", %{markers: socket.assigns.track.cue_points || []})

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:biblioteca}>
      <div class="mx-auto max-w-5xl px-6 py-5">
        <.link navigate={~p"/"} class="text-body-sm text-ink-muted hover:text-ink">
          ← Biblioteca
        </.link>

        <header class="mt-4 flex gap-5">
          <.cover src={cover_src(@track)} artist={@track.tag_artist} size={84} />
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-[23px] font-semibold">{title(@track)}</h1>
            <p class="text-body-lg text-ink-secondary">{@track.tag_artist || "—"}</p>
            <div class="mt-3 flex items-center gap-4">
              <.folder_badge :if={@track.genre_folder} folder={@track.genre_folder} />
              <.stat label="BPM" value={bpm(@track)} class="text-primary" />
              <div class="flex items-center gap-1.5">
                <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Tom</span>
                <.camelot_seal value={camelot(@track)} />
              </div>
              <.confidence_chip level={@track.sc_match_confidence} />
            </div>
          </div>
        </header>

        <section class="mt-5 rounded-xl border border-white/6 bg-surface p-4">
          <div class="flex items-center justify-between">
            <.section_label>Player</.section_label>
            <div class="flex items-center gap-2">
              <button
                id="wf-toggle"
                phx-click={JS.dispatch("beatgrid:toggle", to: "#track-waveform")}
                class="flex size-8 items-center justify-center rounded-full bg-primary/15 text-[12px] text-primary hover:bg-primary/25"
                title="Tocar / pausar"
              >
                ▶
              </button>
              <button
                phx-click={JS.dispatch("beatgrid:mark", to: "#track-waveform")}
                class="rounded-md border border-amber/40 bg-amber/10 px-2.5 py-1 text-[11px] font-semibold text-amber hover:bg-amber/20"
              >
                + Marcar aqui
              </button>
            </div>
          </div>

          <div class="relative mt-3">
            <div
              id="track-waveform"
              phx-hook="Waveform"
              phx-update="ignore"
              data-audio={~p"/audio/#{@track.id}"}
              data-markers={Jason.encode!(@track.cue_points || [])}
            >
            </div>
          </div>

          <div :if={(@track.cue_points || []) != []} class="mt-3 flex flex-wrap gap-1.5">
            <div
              :for={m <- @track.cue_points}
              class="inline-flex items-center gap-1.5 rounded-sm border border-amber/40 bg-amber/10 px-2 py-1 text-[11px]"
            >
              <button
                phx-click={
                  JS.dispatch("beatgrid:seek", to: "#track-waveform", detail: %{ms: m["ms"]})
                }
                class="font-mono text-amber hover:underline"
                title="Pular para este ponto"
              >
                {format_ms(m["ms"])}
              </button>
              <span :if={m["label"]} class="text-ink-secondary">{m["label"]}</span>
              <button
                phx-click="remove_marker"
                phx-value-ms={m["ms"]}
                class="text-ink-muted hover:text-coral"
                title="Remover marcador"
              >
                ✕
              </button>
            </div>
          </div>
        </section>

        <section class="mt-5 rounded-xl border border-white/6 bg-surface p-4">
          <div class="flex items-center justify-between">
            <.section_label>Análise (Soundcharts × local)</.section_label>
            <button
              phx-click="reanalyze"
              disabled={@analyzing?}
              class="rounded-md border border-white/10 bg-input px-2.5 py-1 text-[11px] text-ink-secondary hover:text-ink disabled:opacity-50"
            >
              {if @analyzing?, do: "Analisando…", else: "Re-analisar"}
            </button>
          </div>
          <div class="mt-3 grid grid-cols-2 gap-4">
            <div>
              <p class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
                Soundcharts
              </p>
              <div class="mt-1 flex items-center gap-2 text-body-sm">
                <span class="font-mono text-primary">{sc_bpm(@track) || "—"}</span>
                <span class="text-ink-faint">BPM</span>
                <.camelot_seal value={sc_camelot(@track)} />
              </div>
            </div>
            <div>
              <p class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
                Detectado (local)
              </p>
              <div class="mt-1 flex items-center gap-2 text-body-sm">
                <span class="font-mono text-amber">
                  {(@track.bpm_detected && round(@track.bpm_detected)) ||
                    if(@analyzing?, do: "…", else: "—")}
                </span>
                <span class="text-ink-faint">BPM</span>
                <.camelot_seal value={@track.camelot_detected} />
              </div>
            </div>
          </div>
          <p :if={bpm_discrepancy?(@track)} class="mt-2 text-caption text-amber">
            ⚠ Os BPMs divergem bastante (possível erro de dobro/metade) — confira ouvindo na onda.
          </p>
        </section>

        <div class="mt-6 grid grid-cols-1 gap-5 lg:grid-cols-2">
          <section class="rounded-xl border border-white/6 bg-surface p-4">
            <.section_label>Metadados</.section_label>
            <dl class="mt-3 space-y-1.5">
              <div :for={{k, v} <- meta_rows(@track)} class="flex justify-between gap-4 text-body-sm">
                <dt class="text-ink-faint">{k}</dt>
                <dd class="truncate text-right text-ink-secondary">{v}</dd>
              </div>
            </dl>
            <.audio_profile :if={@track.soundcharts_song} song={@track.soundcharts_song} />
          </section>

          <div class="space-y-5">
            <section class="rounded-xl border border-white/6 bg-surface p-4">
              <.section_label>Minha nota</.section_label>
              <div class="mt-3"><.rating_control value={@track.rating} /></div>
            </section>

            <section class="rounded-xl border border-white/6 bg-surface p-4">
              <.section_label>Minhas tags</.section_label>
              <div class="mt-3 flex flex-wrap gap-1.5">
                <span
                  :for={tag <- @track.tags || []}
                  class="inline-flex items-center gap-1 rounded-sm border border-primary/40 bg-primary/15 px-2 py-1 text-[11px] text-ink"
                >
                  {tag}
                  <button
                    phx-click="remove_tag"
                    phx-value-tag={tag}
                    class="text-ink-muted hover:text-coral"
                  >✕</button>
                </span>
                <span :if={(@track.tags || []) == []} class="text-body-sm text-ink-faint">Sem tags ainda.</span>
              </div>
              <form id="track-add-tag" phx-submit="add_tag" class="mt-2.5 flex gap-2">
                <input
                  type="text"
                  name="tag"
                  value={@tag_draft}
                  placeholder="+ nova tag"
                  class="flex-1 rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm focus:border-primary/50 focus:outline-none"
                />
                <button class="rounded-md bg-primary px-3 py-1.5 text-body-sm font-semibold text-white">Adicionar</button>
              </form>
            </section>

            <section class="rounded-xl border border-white/6 bg-surface p-4">
              <.section_label>Anotação pessoal</.section_label>
              <form id="track-note" phx-change="save_note" class="mt-3">
                <textarea
                  name="note"
                  rows="3"
                  phx-debounce="600"
                  placeholder="Observações suas sobre a faixa…"
                  class="w-full resize-none rounded-md border border-white/8 bg-input px-3 py-2 text-body-sm focus:border-primary/50 focus:outline-none"
                >{@track.personal_note}</textarea>
              </form>
            </section>
          </div>
        </div>

        <section class="mt-6 rounded-xl border border-white/6 bg-surface p-4">
          <div class="flex items-center justify-between">
            <.section_label>Próxima faixa ideal (harmônica)</.section_label>
            <button
              phx-click="start_set"
              class="rounded-md bg-primary px-2.5 py-1 text-[12px] font-semibold text-white"
            >
              + Começar set
            </button>
          </div>
          <div :if={@next != []} class="mt-3 space-y-1">
            <.link
              :for={s <- @next}
              navigate={~p"/track/#{s.track.id}"}
              class="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-surface-2"
            >
              <.cover src={cover_src(s.track)} artist={s.track.tag_artist} size={34} />
              <div class="min-w-0 flex-1">
                <p class="truncate text-body font-medium">{title(s.track)}</p>
                <p class="truncate text-caption text-ink-muted">{s.track.tag_artist || "—"}</p>
              </div>
              <.camelot_seal value={s.camelot} />
              <span class="w-12 text-right font-mono text-body text-primary">{round(s.bpm)}</span>
            </.link>
          </div>
          <p :if={@next == []} class="mt-3 text-body-sm text-ink-faint">
            Sem sugestões harmônicas (faixa sem tom/BPM, ou nada compatível).
          </p>
        </section>
      </div>
    </.app_shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: ""

  defp stat(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">{@label}</span>
      <span class={["font-mono text-body-lg", @class]}>{@value}</span>
    </div>
    """
  end

  slot :inner_block, required: true

  defp section_label(assigns) do
    ~H"""
    <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :song, :any, required: true

  defp audio_profile(assigns) do
    ~H"""
    <div class="mt-4 space-y-2">
      <.section_label>Perfil de áudio</.section_label>
      <.feature_bar :for={{label, value} <- audio_features(@song)} label={label} value={value} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :float, required: true

  defp feature_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="w-24 text-[11px] text-ink-muted">{@label}</span>
      <div class="h-[6px] flex-1 rounded-full bg-white/5">
        <div class="h-full rounded-full bg-green" style={"width:#{round(@value * 100)}%"} />
      </div>
      <span class="w-8 text-right font-mono text-[11px] text-ink-secondary">{round(@value * 100)}</span>
    </div>
    """
  end

  defp audio_features(song) do
    [
      {"Energia", song.energy},
      {"Valência", song.valence},
      {"Dançabilidade", song.danceability},
      {"Acústico", song.acousticness}
    ]
    |> Enum.filter(fn {_l, v} -> is_number(v) end)
  end

  defp meta_rows(track) do
    (base_rows(track) ++ song_rows(track.soundcharts_song))
    |> Enum.reject(fn {_k, v} -> v in [nil, "", false] end)
  end

  defp base_rows(track) do
    [
      {"Pasta", folder_label(track.genre_folder)},
      {"Duração", track.duration_ms && format_secs(div(track.duration_ms, 1000))},
      {"Formato", track.format},
      {"Bitrate", track.bitrate_kbps && "#{track.bitrate_kbps} kbps"},
      {"Arquivo", track.rel_path}
    ]
  end

  defp song_rows(nil), do: []

  defp song_rows(song) do
    [
      {"Artista (nuvem)", song.credit_name},
      {"ISRC", song.isrc},
      {"Ano", song.release_date && song.release_date.year},
      {"Gravadora", song.label},
      {"Gêneros", genres(song)},
      {"Compasso", song.time_signature && "#{song.time_signature}/4"},
      {"Idioma", song.language_code}
    ]
  end

  defp genres(song) do
    case Enum.uniq((song.subgenres || []) ++ (song.genres || [])) do
      [] -> nil
      list -> Enum.join(list, ", ")
    end
  end

  defp format_secs(s), do: "#{div(s, 60)}:#{String.pad_leading(to_string(rem(s, 60)), 2, "0")}"

  defp format_ms(ms) when is_integer(ms), do: format_secs(div(ms, 1000))
  defp format_ms(_ms), do: "0:00"

  defp title(track), do: track.tag_title || track.filename

  # Effective BPM/Tom for the header: Soundcharts value, falling back to detected.
  defp bpm(%{soundcharts_song: %{tempo_bpm: b}}) when is_number(b), do: round(b)
  defp bpm(%{bpm_detected: b}) when is_number(b), do: round(b)
  defp bpm(_track), do: "—"

  defp camelot(%{soundcharts_song: %{camelot: c}}) when is_binary(c), do: c
  defp camelot(%{camelot_detected: c}) when is_binary(c), do: c
  defp camelot(_track), do: nil

  # Source-specific values for the analysis breakdown.
  defp sc_bpm(%{soundcharts_song: %{tempo_bpm: b}}) when is_number(b), do: round(b)
  defp sc_bpm(_track), do: nil

  defp sc_camelot(%{soundcharts_song: %{camelot: c}}) when is_binary(c), do: c
  defp sc_camelot(_track), do: nil

  # Flag when Soundcharts and local BPM disagree by more than 10% (incl. half/double).
  defp bpm_discrepancy?(%{soundcharts_song: %{tempo_bpm: a}, bpm_detected: b})
       when is_number(a) and is_number(b) and a > 0 and b > 0,
       do: abs(a - b) / max(a, b) > 0.1

  defp bpm_discrepancy?(_track), do: false
end
