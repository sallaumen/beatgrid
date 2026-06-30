defmodule BeatgridWeb.TrackLive do
  @moduledoc "Detalhe da faixa — metadata, rating, tags, note, harmonic next track."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Analysis
  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Loudness
  alias Beatgrid.Mixing
  alias Beatgrid.Playback
  alias Beatgrid.Repertoire
  alias Beatgrid.Sets
  alias Beatgrid.Workers.{AnalyzeWorker, EnrichWorker, MarkerAnalyzeWorker, RecommendWorker}
  alias Beatgrid.YouTube
  alias Phoenix.LiveView.JS

  # The only fields the inline pencils may edit. `phx-value-field` is client-supplied,
  # so edit_field whitelists against this before any String.to_existing_atom.
  @editable_fields ~w(title artist album year genre bpm key filename)

  # Extensions we treat as a "real" audio extension when the user renames a file —
  # anything else (or a name with no extension) keeps the original extension.
  @audio_exts ~w(.mp3 .m4a .flac .wav .aac .ogg)

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
           versions: Tracks.versions_of(track),
           next: Mixing.rank(prev: track, exclude: [track.id], limit: 8),
           tag_draft: "",
           editing_field: nil,
           all_tags: Tracks.all_tags(),
           rename_undo: nil,
           analyzing?: false,
           enriching?: false,
           recs: load_recs(track.id),
           recommending?: false,
           toast: nil,
           playing_track_id: Playback.now_playing().track_id,
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
      Playback.subscribe()
      Playback.subscribe_markers()
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

      {:noreply,
       socket |> save(%{tags: tags}) |> assign(tag_draft: "", all_tags: Tracks.all_tags())}
    end
  end

  def handle_event("remove_tag", %{"tag" => tag}, socket) do
    {:noreply,
     socket
     |> save(%{tags: (socket.assigns.track.tags || []) -- [tag]})
     |> assign(all_tags: Tracks.all_tags())}
  end

  def handle_event("save_note", %{"note" => note}, socket) do
    {:noreply, save(socket, %{personal_note: note})}
  end

  # --- inline field editing ---

  def handle_event("edit_field", %{"field" => field}, socket) when field in @editable_fields do
    {:noreply, assign(socket, editing_field: String.to_existing_atom(field))}
  end

  def handle_event("edit_field", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_field: nil)}
  end

  def handle_event("save_field", %{"field" => field, "value" => value}, socket) do
    {:noreply,
     socket |> apply_field_edit(field, String.trim(value)) |> assign(editing_field: nil)}
  end

  def handle_event("undo_rename", _params, socket) do
    case socket.assigns.rename_undo do
      nil ->
        {:noreply, socket}

      old ->
        case Library.rename(socket.assigns.track, old) do
          {:ok, %{filename: ^old}} ->
            {:noreply, socket |> reload() |> assign(rename_undo: nil)}

          {:ok, _suffixed} ->
            # The original name was taken again in the meantime; rename/2 kept the
            # file safe with a " (N)" suffix rather than overwriting. Tell the user.
            {:noreply,
             socket
             |> reload()
             |> assign(
               rename_undo: nil,
               toast: {:error, "O nome original já estava em uso; restaurado com sufixo."}
             )}

          {:error, _reason} ->
            {:noreply, assign(socket, toast: {:error, "Não foi possível desfazer a renomeação."})}
        end
    end
  end

  def handle_event("dismiss_rename", _params, socket),
    do: {:noreply, assign(socket, rename_undo: nil)}

  def handle_event("start_set", _params, socket) do
    track = socket.assigns.track
    {:ok, set} = Sets.create("Set: #{title(track)}")
    Sets.append(set, track)
    {:noreply, push_navigate(socket, to: ~p"/set")}
  end

  # Markers live on the global player now; this page only renames/removes them (the
  # ＋ button dispatches to the player, which captures the live position). `mutate_markers`
  # rejects junk ms (no crash), re-reads the track fresh (no lost update vs a player-side
  # edit), persists, reloads, and broadcasts so the player + this page stay in sync.
  def handle_event("rename_marker", %{"ms" => ms, "label" => label}, socket),
    do: {:noreply, mutate_markers(socket, ms, &Tracks.rename_marker(&1, &2, label))}

  def handle_event("remove_marker", %{"ms" => ms}, socket),
    do: {:noreply, mutate_markers(socket, ms, &Tracks.remove_marker(&1, &2))}

  def handle_event("set_marker_type", %{"ms" => ms, "type" => type}, socket),
    do: {:noreply, mutate_markers(socket, ms, &Tracks.set_marker_type(&1, &2, type))}

  def handle_event("detect_markers", _params, socket) do
    Oban.insert(MarkerAnalyzeWorker.new(%{"track_id" => socket.assigns.track.id}))

    {:noreply,
     put_flash(socket, :info, "Detectando marcadores… (intro/saída por análise de áudio)")}
  end

  def handle_event("reanalyze", _params, socket) do
    {:noreply, enqueue_analyze(socket)}
  end

  def handle_event("enrich_track", _params, socket) do
    if Beatgrid.Integrations.configured?(:soundcharts) do
      id = socket.assigns.track.id
      bid = Uniq.UUID.uuid7()
      Oban.insert(EnrichWorker.new(%{"scope" => "track", "id" => id, "batch_id" => bid}))
      {:noreply, assign(socket, enriching?: true, toast: nil)}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Configure SOUNDCHARTS_APP_ID + SOUNDCHARTS_API_KEY no .env."
       )}
    end
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

  # Permanent delete (file + DB row). The `data-confirm` on the button guards it;
  # there is no undo, so we navigate back to the library afterwards. Re-fetch first
  # so a double-fire (already deleted) just navigates instead of crashing.
  def handle_event("delete_track", _params, socket) do
    case Tracks.get(socket.assigns.track.id) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      track ->
        case Library.hard_delete(track) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Faixa apagada.") |> push_navigate(to: ~p"/")}

          {:error, _reason} ->
            {:noreply, assign(socket, toast: {:error, "Não foi possível apagar a faixa."})}
        end
    end
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

  # Global now-playing pointer changed — light up this page if it's our track.
  def handle_info({:now_playing, np}, socket) do
    {:noreply, assign(socket, playing_track_id: np.track_id)}
  end

  # Our track's cue points changed (e.g. a marker added from the player) — reload the list.
  def handle_info({:markers_changed, id}, %{assigns: %{track: %{id: id}}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info({:markers_changed, _id}, socket), do: {:noreply, socket}

  defp enrich_done_toast(%{budget_exhausted: true}), do: {:error, "Cota Soundcharts esgotada."}

  defp enrich_done_toast(%{resolved: r}) when is_integer(r) and r > 0,
    do: {:ok, "Metadados atualizados — revise na Central de Revisão."}

  defp enrich_done_toast(_p), do: {:ok, "Sem match no Soundcharts; classificação atualizada."}

  # BPM/tom: a manual override (wins over Soundcharts/detected); blank reverts to auto,
  # invalid is ignored. Metadata: writes the tag_* column and tracks the field in
  # manual_fields (for the "edited" dot); blank clears it.
  defp apply_field_edit(socket, "bpm", ""), do: save(socket, %{bpm_manual: nil})

  defp apply_field_edit(socket, "bpm", value) do
    case Float.parse(value) do
      {n, _} when n > 0 -> save(socket, %{bpm_manual: Float.round(n, 1)})
      _ -> socket
    end
  end

  defp apply_field_edit(socket, "key", ""), do: save(socket, %{camelot_manual: nil})

  defp apply_field_edit(socket, "key", value) do
    if value =~ ~r/^(1[0-2]|[1-9])[ab]$/i,
      do: save(socket, %{camelot_manual: String.upcase(value)}),
      else: socket
  end

  defp apply_field_edit(socket, "year", ""),
    do: save_metadata(socket, "year", :tag_year, nil)

  # A blank year clears it; garbage ("19xx", "abc") is ignored so a typo can't
  # silently wipe a good year — mirrors the bpm/key override behaviour.
  defp apply_field_edit(socket, "year", value) do
    case parse_year(value) do
      nil -> socket
      year -> save_metadata(socket, "year", :tag_year, year)
    end
  end

  defp apply_field_edit(socket, field, value) when field in ~w(title artist album genre),
    do: save_metadata(socket, field, String.to_existing_atom("tag_#{field}"), blank_to_nil(value))

  defp apply_field_edit(socket, "filename", ""), do: socket

  defp apply_field_edit(socket, "filename", value) do
    track = socket.assigns.track
    old = track.filename

    case Library.rename(track, ensure_ext(value, old)) do
      {:ok, _renamed} ->
        socket |> reload() |> assign(rename_undo: old)

      {:error, :invalid_filename} ->
        assign(socket,
          toast: {:error, "Nome de arquivo inválido (use apenas um nome, sem barras)."}
        )

      {:error, _reason} ->
        assign(socket, toast: {:error, "Não foi possível renomear o arquivo."})
    end
  end

  defp apply_field_edit(socket, _field, _value), do: socket

  # Keep the original extension unless the user typed a real audio extension. Can't
  # rely on `Path.extname == ""` — "Mr. Big - Song" has a non-empty extname (". Big
  # - Song") yet no real extension, so checking against @audio_exts is what keeps
  # the file playable.
  defp ensure_ext(name, fallback) do
    if String.downcase(Path.extname(name)) in @audio_exts,
      do: name,
      else: name <> Path.extname(fallback)
  end

  defp save_metadata(socket, field, column, value) do
    track = socket.assigns.track
    current = track.manual_fields || []

    manual_fields =
      cond do
        # Blank clears the override and the "edited" mark.
        value in [nil, ""] -> List.delete(current, field)
        # Re-submitting the existing value (e.g. Enter without changes) is not an
        # edit — don't light up the "•" dot for a no-op.
        value == Map.get(track, column) -> current
        true -> Enum.uniq([field | current])
      end

    save(socket, %{column => value, :manual_fields => manual_fields})
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Require the whole input to be a positive integer — "19xx" must be rejected
  # (nil), not silently truncated to 19. The "" trailing match enforces that.
  defp parse_year(value) do
    case Integer.parse(value) do
      {y, ""} when y > 0 -> y
      _ -> nil
    end
  end

  defp edited?(track, field), do: field in (track.manual_fields || [])

  defp save(socket, attrs) do
    {:ok, _} = Tracks.update(socket.assigns.track, attrs)
    # Any non-rename edit retires the "Arquivo renomeado · Desfazer" banner so its
    # one-level undo can't dangle past an unrelated change.
    socket |> reload() |> assign(rename_undo: nil)
  end

  defp reload(socket) do
    track = Tracks.get_with_song(socket.assigns.track.id)
    assign(socket, track: track, versions: Tracks.versions_of(track))
  end

  # Parse ms (no crash on junk), re-read the track fresh (no lost update), mutate, reload.
  defp mutate_markers(socket, ms, fun) do
    with {:ok, n} <- to_ms(ms),
         track when not is_nil(track) <- Tracks.get_with_song(socket.assigns.track.id) do
      {:ok, _} = fun.(track, n)
      Playback.broadcast_markers_changed(track.id)
      reload(socket)
    else
      _ -> socket
    end
  end

  defp to_ms(ms) when is_integer(ms), do: {:ok, ms}

  defp to_ms(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {n, _rest} -> {:ok, n}
      :error -> :error
    end
  end

  defp to_ms(_ms), do: :error

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
          <div class={[
            "shrink-0 rounded-xl",
            @track.id == @playing_track_id && "ring-2 ring-primary"
          ]}>
            <.cover src={cover_src(@track)} artist={@track.tag_artist} size={84} />
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex min-w-0 items-center gap-2">
              <h1 class="truncate text-[23px] font-semibold">{title(@track)}</h1>
              <.ouro_badge track={@track} />
              <span
                :if={@track.id == @playing_track_id}
                class="inline-flex shrink-0 items-center gap-1.5 rounded-full bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary"
              >
                <.vinyl size={12} /> Tocando agora
              </span>
            </div>
            <p class="text-body-lg text-ink-secondary">{@track.tag_artist || "—"}</p>
            <div class="mt-3 flex items-center gap-4">
              <.folder_badge :if={@track.genre_folder} folder={@track.genre_folder} />
              <.stat label="BPM" value={bpm(@track)} class="text-primary" />
              <div class="flex items-center gap-1.5">
                <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Tom</span>
                <.camelot_seal value={camelot(@track)} />
              </div>
              <.stat
                :if={@track.loudness_lufs}
                label="Vol."
                value={format_gain(Loudness.gain_db(@track.loudness_lufs, @track.true_peak_dbtp))}
              />
              <.confidence_chip level={@track.sc_match_confidence} />
              <button
                phx-click="enrich_track"
                data-confirm="Atualizar metadados consulta o Soundcharts (gasta cota). Continuar?"
                disabled={@enriching? or not Beatgrid.Integrations.configured?(:soundcharts)}
                class="ml-auto rounded-md border border-primary/40 bg-primary/10 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/20 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {if @enriching?, do: "Atualizando…", else: "Atualizar metadados"}
              </button>
              <.integration_gate key={:soundcharts} />
              <button
                phx-click="delete_track"
                data-confirm="Apagar esta faixa de vez? O arquivo sai do disco e não tem volta."
                class="rounded-md border border-coral/40 px-2.5 py-1 text-[11px] font-semibold text-coral hover:bg-coral/10"
                title="Apagar faixa"
              >
                Apagar
              </button>
            </div>
          </div>

          <div class="flex shrink-0 flex-col items-end gap-2">
            <button
              type="button"
              phx-click={
                if @track.id == @playing_track_id,
                  do: JS.dispatch("beatgrid:toggle", to: "#player-audio"),
                  else:
                    JS.dispatch("beatgrid:play",
                      to: "#player-audio",
                      detail: %{src: ~p"/audio/#{@track.id}", id: @track.id, preview: false}
                    )
              }
              class="flex items-center gap-2 rounded-full bg-primary px-5 py-2.5 text-[15px] font-semibold text-white shadow-lg shadow-primary/30 hover:bg-primary/90"
              title="Tocar no player"
            >
              <.vinyl :if={@track.id == @playing_track_id} size={18} />
              <span :if={@track.id != @playing_track_id} aria-hidden="true">▶</span>
              {if @track.id == @playing_track_id, do: "Tocando", else: "Tocar"}
            </button>
            <button
              type="button"
              phx-click={JS.dispatch("beatgrid:add-marker", to: "#player-audio")}
              disabled={@track.id != @playing_track_id}
              class="flex items-center gap-1.5 rounded-full border border-amber/40 bg-amber/10 px-3.5 py-1.5 text-[12px] font-semibold text-amber hover:bg-amber/20 disabled:cursor-not-allowed disabled:opacity-40"
              title={
                if @track.id == @playing_track_id,
                  do: "Marcar a posição atual",
                  else: "Dê play nesta faixa para marcar"
              }
            >
              <span aria-hidden="true">＋</span> Marcar
            </button>
          </div>
        </header>

        <section class="mt-5 rounded-xl border border-white/6 bg-surface p-4">
          <.section_label>Dados (editáveis)</.section_label>
          <div class="divide-y divide-white/4 mt-2">
            <.editable_row
              field={:title}
              label="Título"
              value={@track.tag_title}
              display={@track.tag_title}
              editing={@editing_field}
              edited?={edited?(@track, "title")}
              placeholder={@track.filename}
            />
            <.editable_row
              field={:artist}
              label="Artista"
              value={@track.tag_artist}
              display={@track.tag_artist}
              editing={@editing_field}
              edited?={edited?(@track, "artist")}
            />
            <.editable_row
              field={:album}
              label="Álbum"
              value={@track.tag_album}
              display={@track.tag_album}
              editing={@editing_field}
              edited?={edited?(@track, "album")}
            />
            <.editable_row
              field={:year}
              label="Ano"
              type="number"
              value={@track.tag_year}
              display={@track.tag_year}
              editing={@editing_field}
              edited?={edited?(@track, "year")}
            />
            <.editable_row
              field={:genre}
              label="Gênero"
              value={@track.tag_genre}
              display={@track.tag_genre}
              editing={@editing_field}
              edited?={edited?(@track, "genre")}
            />
            <.editable_row
              field={:bpm}
              label="BPM"
              type="number"
              value={@track.bpm_manual}
              display={bpm(@track)}
              editing={@editing_field}
              edited?={not is_nil(@track.bpm_manual)}
              placeholder="auto"
            />
            <.editable_row
              field={:key}
              label="Tom"
              value={@track.camelot_manual}
              display={camelot(@track)}
              editing={@editing_field}
              edited?={not is_nil(@track.camelot_manual)}
              placeholder="ex. 8A"
            />
            <.editable_row
              field={:filename}
              label="Arquivo"
              value={@track.filename}
              display={@track.filename}
              editing={@editing_field}
            />
          </div>
          <div
            :if={@rename_undo}
            class="mt-2 flex items-center justify-between gap-3 rounded-lg border border-green/30 bg-green/10 px-3 py-2 text-body-sm"
          >
            <span class="truncate">Arquivo renomeado no disco.</span>
            <div class="flex shrink-0 items-center gap-3">
              <button phx-click="undo_rename" class="font-semibold text-primary hover:underline">
                Desfazer
              </button>
              <button
                phx-click="dismiss_rename"
                class="text-ink-muted hover:text-ink"
                title="Dispensar"
              >
                ✕
              </button>
            </div>
          </div>
        </section>

        <section
          :if={@versions != []}
          class="mt-5 rounded-xl border border-white/6 bg-surface p-4"
        >
          <.section_label>Outras versões ({length(@versions)})</.section_label>
          <ul class="mt-2 divide-y divide-white/4">
            <li :for={v <- @versions} class="flex items-center gap-3 py-2">
              <.link
                navigate={~p"/track/#{v.id}"}
                class="min-w-0 flex-1 truncate text-body-sm hover:text-primary"
              >
                {title(v)}
              </.link>
              <span
                :if={ver_label(v)}
                class="shrink-0 rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] uppercase tracking-wide text-ink-muted"
              >
                {ver_label(v)}
              </span>
              <span :if={ver_dur(v)} class="shrink-0 font-mono text-[11px] text-ink-faint">
                {ver_dur(v)}
              </span>
            </li>
          </ul>
        </section>

        <section class="mt-5 rounded-xl border border-white/6 bg-surface p-4">
          <div class="flex items-center justify-between">
            <.section_label>Marcadores</.section_label>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="detect_markers"
                class="rounded-md border border-white/10 bg-input px-2.5 py-1 text-[11px] text-ink-secondary hover:text-ink"
                title="Detectar intro/saída automaticamente por análise de áudio (mantém os manuais)"
              >
                Detectar
              </button>
              <button
                type="button"
                phx-click={JS.dispatch("beatgrid:add-marker", to: "#player-audio")}
                disabled={@track.id != @playing_track_id}
                class="rounded-md border border-amber/40 bg-amber/10 px-2.5 py-1 text-[11px] font-semibold text-amber hover:bg-amber/20 disabled:cursor-not-allowed disabled:opacity-40"
                title={
                  if @track.id == @playing_track_id,
                    do: "Marcar a posição atual",
                    else: "Dê play nesta faixa para marcar"
                }
              >
                ＋ marcar
              </button>
            </div>
          </div>
          <p class="text-caption text-ink-faint mt-1">
            Aparecem no player de baixo em qualquer página. Clique no tempo para tocar a faixa a partir dele.
          </p>
          <div class="mt-3">
            <.marker_list
              markers={@track.cue_points || []}
              track_id={@track.id}
              play_src={~p"/audio/#{@track.id}"}
              seekable={false}
              id_prefix="track"
            />
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

          <div class="mt-3 border-t border-white/6 pt-3">
            <p class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
              Loudness
              <span class="text-ink-faint">· alvo {format_lufs(Loudness.target_lufs())}</span>
            </p>
            <div
              :if={@track.loudness_lufs}
              class="mt-1 flex flex-wrap items-center gap-x-4 gap-y-1 text-body-sm"
            >
              <span>
                <span class="text-amber font-mono">{format_lufs(@track.loudness_lufs)}</span>
                <span class="text-ink-faint">integrado</span>
              </span>
              <span :if={@track.true_peak_dbtp}>
                <span class="text-ink-secondary font-mono">{Float.round(@track.true_peak_dbtp, 1)} dBTP</span>
                <span class="text-ink-faint">true-peak</span>
              </span>
              <span>
                <span class="font-mono text-primary">
                  {format_gain(Loudness.gain_db(@track.loudness_lufs, @track.true_peak_dbtp))}
                </span>
                <span class="text-ink-faint">ganho sugerido</span>
              </span>
            </div>
            <p :if={!@track.loudness_lufs} class="text-ink-faint mt-1 text-caption">
              Ainda não medido — rode “Analisar loudness” no Painel.
            </p>
          </div>
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
                  list="tag-suggestions"
                  placeholder="+ nova tag"
                  class="flex-1 rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm focus:border-primary/50 focus:outline-none"
                />
                <datalist id="tag-suggestions">
                  <option :for={t <- @all_tags} value={t} />
                </datalist>
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

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :display, :any, default: nil
  attr :editing, :atom, default: nil
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: ""
  attr :edited?, :boolean, default: false

  defp editable_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 py-1.5">
      <span class="w-20 shrink-0 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        {@label}
      </span>
      <form
        :if={@editing == @field}
        phx-submit="save_field"
        class="flex min-w-0 flex-1 items-center gap-1.5"
      >
        <input type="hidden" name="field" value={@field} />
        <input
          type={@type}
          name="value"
          value={@value}
          placeholder={@placeholder}
          phx-mounted={JS.focus()}
          phx-keydown="cancel_edit"
          phx-key="Escape"
          class="min-w-0 flex-1 rounded-md border border-primary/50 bg-input px-2 py-1 text-body-sm focus:outline-none"
        />
        <button class="text-green text-[13px]" title="Salvar">✓</button>
        <button
          type="button"
          phx-click="cancel_edit"
          class="text-ink-muted hover:text-ink text-[13px]"
          title="Cancelar"
        >
          ✕
        </button>
      </form>
      <span :if={@editing != @field} class="group/ed flex min-w-0 flex-1 items-center gap-1.5">
        <span class={["truncate text-body-sm", @display in [nil, ""] && "text-ink-faint"]}>
          {(@display in [nil, ""] && "—") || @display}
        </span>
        <span :if={@edited?} class="shrink-0 text-[11px] text-primary" title="editado manualmente">
          •
        </span>
        <button
          type="button"
          phx-click="edit_field"
          phx-value-field={@field}
          class="text-ink-faint hover:text-ink shrink-0 opacity-0 transition-opacity group-hover/ed:opacity-100"
          title="Editar"
        >
          <span class="hero-pencil-square size-3.5" />
        </button>
      </span>
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

  defp title(track), do: track.tag_title || track.filename

  defp ver_label(track), do: Beatgrid.Library.Version.label(track.tag_title || track.filename)

  defp ver_dur(%{duration_ms: ms}) when is_integer(ms) and ms > 0, do: format_secs(div(ms, 1000))
  defp ver_dur(_track), do: nil

  # Effective BPM/Tom for the header: Soundcharts value, falling back to detected.
  defp bpm(%{bpm_manual: b}) when is_number(b), do: round(b)
  defp bpm(%{soundcharts_song: %{tempo_bpm: b}}) when is_number(b), do: round(b)
  defp bpm(%{bpm_detected: b}) when is_number(b), do: round(b)
  defp bpm(_track), do: "—"

  defp camelot(%{camelot_manual: c}) when is_binary(c), do: c
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
