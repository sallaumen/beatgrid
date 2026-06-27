defmodule BeatgridWeb.TrackLive do
  @moduledoc "Detalhe da faixa — metadata, rating, tags, note, harmonic next track."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Analysis
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Mixing
  alias Beatgrid.Repertoire
  alias Beatgrid.Sets
  alias Beatgrid.Workers.{AnalyzeWorker, EnrichWorker, RecommendWorker}
  alias Beatgrid.YouTube
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
           next: Mixing.rank(prev: track, exclude: [track.id], limit: 8),
           tag_draft: "",
           analyzing?: false,
           enriching?: false,
           recs: load_recs(track.id),
           recommending?: false,
           toast: nil,
           page_title: title(track)
         )
         |> maybe_auto_analyze()}
    end
  end

  defp load_recs(track_id),
    do:
      Repertoire.list_recommendations(
        track_id: track_id,
        source: :match,
        statuses: [:new, :imported]
      )

  # Auto-run local analysis the first time a track is opened without it. Runs in
  # the background (AnalyzeWorker), so it survives navigation; the `unique`
  # constraint dedupes if a job is already in flight. Connected mount only, so we
  # subscribe + enqueue once over the websocket — not during the dead render.
  # Subscribe unconditionally on connected mount (cheap) so re-analyze ticks land.
  defp maybe_auto_analyze(socket) do
    track = socket.assigns.track

    if connected?(socket) do
      Analysis.subscribe()
      YouTube.subscribe_enrich()
      Repertoire.subscribe()
      if is_nil(track.analyzed_at), do: enqueue_analyze(socket), else: socket
    else
      socket
    end
  end

  defp enqueue_analyze(socket) do
    Oban.insert(AnalyzeWorker.new(%{track_id: socket.assigns.track.id}))
    assign(socket, analyzing?: true)
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
    {:noreply, enqueue_analyze(socket)}
  end

  def handle_event("enrich_track", _params, socket) do
    id = socket.assigns.track.id
    bid = Uniq.UUID.uuid7()
    Oban.insert(EnrichWorker.new(%{"scope" => "track", "id" => id, "batch_id" => bid}))
    {:noreply, assign(socket, enriching?: true, toast: nil)}
  end

  def handle_event("fetch_matches", _params, socket) do
    Oban.insert(
      RecommendWorker.new(%{
        "scope" => "track",
        "track_id" => socket.assigns.track.id,
        "batch_id" => Uniq.UUID.uuid7()
      })
    )

    {:noreply, assign(socket, recommending?: true)}
  end

  def handle_event("download_rec", %{"id" => id}, socket) do
    toast =
      case Repertoire.get_recommendation(id) do
        nil ->
          socket.assigns.toast

        rec ->
          YouTube.enqueue("ytsearch1:" <> (rec.youtube_query || ""))
          Repertoire.set_recommendation_status(rec, :imported)
          {:ok, "#{rec.artist} — #{rec.song}: na fila — veja em Jobs."}
      end

    {:noreply, assign(socket, recs: load_recs(socket.assigns.track.id), toast: toast)}
  end

  def handle_event("dismiss_rec", %{"id" => id}, socket) do
    case Repertoire.get_recommendation(id) do
      nil -> :ok
      rec -> Repertoire.set_recommendation_status(rec, :dismissed)
    end

    {:noreply, assign(socket, recs: load_recs(socket.assigns.track.id))}
  end

  def handle_event("dismiss_toast", _params, socket) do
    {:noreply, assign(socket, toast: nil)}
  end

  # A background analysis finished (tick is global; reloading this one track is
  # cheap). Clear `analyzing?` once the reloaded track has its `analyzed_at`.
  @impl true
  def handle_info({:analysis_tick}, socket) do
    socket = reload(socket)
    {:noreply, assign(socket, analyzing?: is_nil(socket.assigns.track.analyzed_at))}
  end

  # This track's enrich job finished (the topic is global; ignore other tracks'
  # progress and the batch/pending scope, which the dashboard owns).
  def handle_info({:enrich_progress, %{id: id, status: :done} = p}, socket)
      when id == socket.assigns.track.id do
    {:noreply, socket |> assign(enriching?: false, toast: enrich_done_toast(p)) |> reload()}
  end

  def handle_info({:enrich_progress, _payload}, socket), do: {:noreply, socket}

  # This track's "songs that pair" recommendation finished. Reload the persisted
  # matches and clear the spinner; ignore ticks for other tracks (topic is global).
  def handle_info({:recommend_progress, %{scope: "track", key: id, status: status}}, socket)
      when status in [:done, :error] do
    if id == socket.assigns.track.id do
      {:noreply, assign(socket, recommending?: false, recs: load_recs(id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:recommend_progress, _payload}, socket), do: {:noreply, socket}

  defp enrich_done_toast(%{budget_exhausted: true}), do: {:error, "Cota Soundcharts esgotada."}

  defp enrich_done_toast(%{resolved: r}) when is_integer(r) and r > 0,
    do: {:ok, "Metadados atualizados — revise na Central de Revisão."}

  defp enrich_done_toast(_p), do: {:ok, "Sem match no Soundcharts; classificação atualizada."}

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
    <.app_shell active={:biblioteca} socket={@socket}>
      <div class="mx-auto max-w-5xl px-6 py-5">
        <.link navigate={~p"/"} class="text-body-sm text-ink-muted hover:text-ink">
          ← Biblioteca
        </.link>

        <.enrich_toast :if={@toast} toast={@toast} />

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
              <button
                phx-click="enrich_track"
                data-confirm="Atualizar metadados consulta o Soundcharts (gasta cota). Continuar?"
                disabled={@enriching?}
                class="ml-auto rounded-md border border-primary/40 bg-primary/10 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/20 disabled:opacity-50"
              >
                {if @enriching?, do: "Atualizando…", else: "Atualizar metadados"}
              </button>
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
              <div
                :if={is_binary((@track.raw_tags || %{})["youtube_url"])}
                class="flex justify-between gap-4 text-body-sm"
              >
                <dt class="text-ink-faint">YouTube</dt>
                <dd class="truncate text-right">
                  <a
                    href={@track.raw_tags["youtube_url"]}
                    target="_blank"
                    rel="noopener"
                    class="text-primary hover:underline"
                  >
                    Abrir vídeo
                  </a>
                </dd>
              </div>
              <div
                :if={is_binary((@track.raw_tags || %{})["youtube_playlist_url"])}
                class="flex justify-between gap-4 text-body-sm"
              >
                <dt class="text-ink-faint">Playlist</dt>
                <dd class="truncate text-right">
                  <a
                    href={@track.raw_tags["youtube_playlist_url"]}
                    target="_blank"
                    rel="noopener"
                    class="text-primary hover:underline"
                  >
                    Abrir playlist
                  </a>
                </dd>
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

        <section class="mt-6 rounded-xl border border-white/6 bg-surface p-4">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <.section_label>Sugestões parecidas (IA)</.section_label>
              <p class="mt-1 text-caption text-ink-faint">
                Faixas de outra origem que combinam com esta — mesmo clima, época e energia.
              </p>
            </div>
            <button
              type="button"
              phx-click="fetch_matches"
              disabled={@recommending?}
              class="inline-flex shrink-0 items-center gap-2 rounded-md bg-primary px-3 py-1.5 text-[12px] font-semibold text-white transition-opacity disabled:opacity-50"
            >
              <span
                :if={@recommending?}
                class="size-2 animate-pulse rounded-full bg-white/90"
                aria-hidden="true"
              ></span>
              {if @recommending?, do: "Gerando…", else: "Buscar parecidas"}
            </button>
          </div>

          <div :if={@recs != []} class="mt-3 space-y-1.5">
            <.rec_row :for={rec <- @recs} rec={rec} />
          </div>

          <div
            :if={@recs == [] and @recommending?}
            class="mt-3 flex items-center gap-2 rounded-lg border border-primary/25 bg-primary/8 px-3 py-3 text-body-sm text-ink-secondary"
          >
            <span class="size-2.5 animate-pulse rounded-full bg-primary" aria-hidden="true"></span>
            Gerando sugestões com a IA… isso pode levar alguns segundos.
          </div>

          <p
            :if={@recs == [] and not @recommending?}
            class="mt-3 rounded-lg border border-dashed border-white/8 px-3 py-4 text-center text-body-sm text-ink-faint"
          >
            Nenhuma sugestão salva para esta faixa. Clique em <span class="text-ink-secondary">Buscar parecidas</span>.
          </p>
        </section>
      </div>
    </.app_shell>
    """
  end

  # One persisted AI match recommendation: `artist — song`, the AI's reason, and the
  # YouTube search / download / dismiss actions. Imported rows wear a "baixada" tag.
  attr :rec, :map, required: true

  defp rec_row(assigns) do
    ~H"""
    <div class={[
      "group rounded-lg border px-3 py-2.5 transition-colors",
      if(@rec.status == :imported,
        do: "border-green/25 bg-green/5",
        else: "border-white/6 bg-base hover:border-white/12"
      )
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <p class="truncate text-body font-medium">
            {@rec.artist} <span class="text-ink-faint">—</span> {@rec.song}
          </p>
          <p :if={@rec.reason} class="mt-0.5 text-caption text-ink-muted">{@rec.reason}</p>
        </div>
        <span
          :if={@rec.status == :imported}
          class="bg-token-chip inline-flex shrink-0 items-center gap-1 rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
          style="--c:#5ad1a0"
        >
          ✓ baixada
        </span>
      </div>

      <div class="mt-2 flex flex-wrap items-center gap-1.5">
        <a
          href={Repertoire.youtube_search_url(@rec)}
          target="_blank"
          rel="noopener"
          class="inline-flex items-center gap-1 rounded-md border border-white/10 bg-input px-2.5 py-1 text-[11px] text-ink-secondary transition-colors hover:text-ink"
        >
          Buscar no YouTube <span class="text-ink-faint" aria-hidden="true">↗</span>
        </a>
        <button
          type="button"
          phx-click="download_rec"
          phx-value-id={@rec.id}
          class="inline-flex items-center gap-1 rounded-md bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary transition-colors hover:bg-primary/25"
        >
          ↓ {if @rec.status == :imported, do: "Baixar de novo", else: "Baixar"}
        </button>
        <button
          type="button"
          phx-click="dismiss_rec"
          phx-value-id={@rec.id}
          class="ml-auto rounded-md px-2.5 py-1 text-[11px] text-ink-muted transition-colors hover:text-coral"
        >
          Dispensar
        </button>
      </div>
    </div>
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

  attr :toast, :any, required: true

  defp enrich_toast(assigns) do
    ~H"""
    <div class={[
      "mb-4 flex items-center justify-between gap-4 rounded-lg border px-4 py-2.5",
      if(match?({:error, _}, @toast),
        do: "border-coral/30 bg-coral/10",
        else: "border-green/30 bg-green/10"
      )
    ]}>
      <p class="text-body-sm text-ink">{enrich_toast_message(@toast)}</p>
      <button phx-click="dismiss_toast" class="text-ink-muted hover:text-ink text-body-sm">✕</button>
    </div>
    """
  end

  defp enrich_toast_message({:ok, msg}), do: msg
  defp enrich_toast_message({:error, msg}), do: msg
end
