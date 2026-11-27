defmodule BeatgridWeb.TrackLive do
  @moduledoc "Detalhe da faixa — metadata, rating, tags, note, harmonic next track."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI
  import BeatgridWeb.RecommendationComponents, only: [rec_row: 1]

  alias Beatgrid.Analysis
  alias Beatgrid.Library
  alias Beatgrid.Library.{GenreFolders, Marker, Tracks}
  alias Beatgrid.Loudness
  alias Beatgrid.Mixing
  alias Beatgrid.Operations
  alias Beatgrid.Playback
  alias Beatgrid.Repertoire
  alias Beatgrid.Sets
  alias Beatgrid.Workers.{AnalyzeWorker, EnrichWorker, MarkerAnalyzeWorker, RecommendWorker}
  alias Beatgrid.YouTube
  alias BeatgridWeb.LibraryNavigation
  alias Phoenix.LiveView.JS

  # The only fields the inline pencils may edit. `phx-value-field` is client-supplied,
  # so edit_field whitelists against this before any String.to_existing_atom.
  @editable_fields ~w(title artist album year genre bpm key filename)

  # Extensions we treat as a "real" audio extension when the user renames a file —
  # anything else (or a name with no extension) keeps the original extension.
  @audio_exts ~w(.mp3 .m4a .flac .wav .aac .ogg)

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    origin = track_origin(params)

    case fetch_track(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "Faixa não encontrada.") |> push_navigate(to: origin.path)}

      track ->
        {:ok,
         socket
         |> assign(
           origin: origin,
           planner: planner_action(origin, track.id),
           track: track,
           folders: GenreFolders.list(),
           versions: Tracks.same_song_versions_of(track),
           gain_backup: Operations.latest_gain_backup(track.id),
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

      if is_nil(track.analyzed_at) and not needs_recovery?(track),
        do: enqueue_analyze(socket),
        else: socket
    else
      socket
    end
  end

  defp enqueue_analyze(socket) do
    {:ok, _job} = AnalyzeWorker.enqueue(socket.assigns.track.id)
    assign(socket, analyzing?: true)
  end

  @impl true
  def handle_event("set_rating", %{"n" => n}, socket) do
    case Integer.parse(n) do
      {rating, ""} -> {:noreply, save(socket, %{rating: rating})}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_gold", _params, socket) do
    {:ok, _} = Library.toggle_gold(socket.assigns.track)
    {:noreply, reload(socket)}
  end

  # Change the track's genre folder. This is a PHYSICAL move on disk (undoable via
  # the operations log) + a genre-tag write, not just a DB field — so it reuses
  # `Library.move_to_folder`. The empty placeholder and a no-op reselection are
  # ignored; failures surface as a toast without leaving a half-moved file.
  def handle_event("change_folder", %{"folder" => key}, socket)
      when key in ["", nil] do
    {:noreply, socket}
  end

  def handle_event("change_folder", %{"folder" => key}, socket) do
    track = socket.assigns.track

    if key == track.genre_folder do
      {:noreply, socket}
    else
      case Library.move_to_folder(track, key) do
        {:ok, _moved, _batch_id} ->
          {:noreply,
           socket |> reload() |> assign(toast: {:ok, "Movida para #{folder_label(key)}."})}

        {:error, :already_there} ->
          {:noreply, socket}

        {:error, :unknown_folder} ->
          {:noreply, assign(socket, toast: {:error, "Pasta desconhecida."})}

        {:error, _reason} ->
          {:noreply, assign(socket, toast: {:error, "Não foi possível mover o arquivo."})}
      end
    end
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

  def handle_event("restore_gain_backup", _params, socket) do
    case Operations.latest_gain_operation(socket.assigns.track.id) do
      nil ->
        {:noreply, assign(socket, toast: {:error, "Nenhum backup original disponível."})}

      operation ->
        toast =
          case Operations.undo_operation(operation) do
            :undone -> {:ok, "Backup original restaurado."}
            :failed -> {:error, "Não foi possível restaurar o backup desta faixa."}
          end

        {:noreply, socket |> reload() |> assign(toast: toast)}
    end
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
    {:ok, _job} = MarkerAnalyzeWorker.enqueue(socket.assigns.track.id)

    {:noreply,
     put_flash(socket, :info, "Detectando marcadores… (intro/saída por análise de áudio)")}
  end

  def handle_event("reanalyze", _params, socket) do
    {:noreply, enqueue_analyze(socket)}
  end

  def handle_event("enrich_track", _params, socket) do
    if Beatgrid.Integrations.configured?(:soundcharts) do
      {:ok, _job} = EnrichWorker.enqueue("track", id: socket.assigns.track.id)
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
    {:ok, _job} = RecommendWorker.enqueue_for_track(socket.assigns.track.id)

    {:noreply, assign(socket, recommending?: true)}
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
  # there is no undo, so we return to the originating screen afterwards. Re-fetch first
  # so a double-fire (already deleted) just navigates instead of crashing.
  def handle_event("delete_track", _params, socket) do
    case Tracks.get(socket.assigns.track.id) do
      nil ->
        {:noreply, push_navigate(socket, to: socket.assigns.origin.path)}

      track ->
        case Library.hard_delete(track) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Faixa apagada.")
             |> push_navigate(to: socket.assigns.origin.path)}

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

    assign(socket,
      track: track,
      versions: Tracks.same_song_versions_of(track),
      gain_backup: Operations.latest_gain_backup(track.id)
    )
  end

  defp fetch_track(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Tracks.get_with_song(uuid)
      :error -> nil
    end
  end

  defp track_origin(%{"set_id" => id} = params) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{} = set <- Sets.get(uuid) do
      %{
        path: ~p"/set/#{set.id}",
        label: "Voltar ao set · #{set.name}",
        set: set,
        params: %{set_id: set.id}
      }
    else
      _ -> library_origin(params)
    end
  end

  defp track_origin(params), do: library_origin(params)

  defp library_origin(params) do
    path = LibraryNavigation.return_path(params["library"])
    query = if path == ~p"/", do: %{}, else: %{library: path}
    %{path: path, label: "Biblioteca", set: nil, params: query}
  end

  defp planner_action(%{set: nil}, id),
    do: %{path: ~p"/set?track_id=#{id}", label: "Usar em um set"}

  defp planner_action(%{set: set}, id) do
    if Sets.member?(set.id, id) do
      %{path: ~p"/set?track_id=#{id}", label: "Usar em outro set"}
    else
      %{path: ~p"/set/#{set.id}?track_id=#{id}", label: "Usar neste set"}
    end
  end

  defp needs_recovery?(track),
    do:
      track.status in [:missing, :quarantined] or
        track.integrity_status in [:missing_file, :corrupt]

  defp file_status(%{status: :quarantined}), do: "Arquivo na quarentena"
  defp file_status(%{status: :missing}), do: "Arquivo ausente"
  defp file_status(%{integrity_status: :missing_file}), do: "Arquivo ausente"
  defp file_status(%{integrity_status: :corrupt}), do: "Arquivo corrompido"

  # Parse ms (no crash on junk), re-read the track fresh (no lost update), mutate, reload.
  defp mutate_markers(socket, ms, fun) do
    with {:ok, n} <- Marker.parse_position(ms),
         track when not is_nil(track) <- Tracks.get_with_song(socket.assigns.track.id),
         {:ok, _} <- fun.(track, n) do
      Playback.broadcast_markers_changed(track.id)
      reload(socket)
    else
      _ -> socket
    end
  end

  @impl true
  def render(assigns) do
    {imported, pending} = Enum.split_with(assigns.recs, &(&1.status == :imported))
    assigns = assign(assigns, pending_recs: pending, imported_recs: imported)

    ~H"""
    <.app_shell flash={@flash} active={:biblioteca} socket={@socket}>
      <div class="mx-auto w-full max-w-[1280px] px-3 py-4 sm:px-5 lg:px-6 lg:py-5">
        <.link
          id="track-return"
          navigate={@origin.path}
          class="inline-flex max-w-full items-center gap-1.5 text-body-sm text-ink-secondary hover:text-ink hover:underline"
        >
          <.icon name="hero-arrow-left-mini" class="size-4 shrink-0" />
          <span class="break-words">{@origin.label}</span>
        </.link>

        <.enrich_toast :if={@toast} toast={@toast} />

        <header class="mt-3 min-w-0 rounded-xl border border-white/6 bg-surface p-4">
          <div class="grid grid-cols-[auto_minmax(0,1fr)] items-start gap-3 md:grid-cols-[auto_minmax(0,1fr)_auto] md:gap-4">
            <div class={[
              "shrink-0 rounded-xl",
              @track.id == @playing_track_id && "ring-2 ring-primary"
            ]}>
              <.cover src={cover_src(@track)} artist={@track.tag_artist} size={82} />
            </div>

            <div class="min-w-0 flex-1">
              <h1 class="min-w-0 break-words text-[24px] font-semibold leading-tight [overflow-wrap:anywhere] sm:text-[28px]">
                {title(@track)}
              </h1>
              <p class="mt-1 break-words text-body-lg text-ink-secondary [overflow-wrap:anywhere]">
                {@track.tag_artist || "—"}
              </p>

              <div class="mt-2 flex min-w-0 flex-wrap items-center gap-2">
                <.track_gold_toggle track={@track} />
                <span
                  :if={@track.id == @playing_track_id}
                  class="inline-flex shrink-0 items-center gap-1.5 rounded-full bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary"
                >
                  <.vinyl size={12} /> Tocando agora
                </span>
              </div>

              <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2">
                <.stat label="BPM" value={bpm(@track)} class="text-primary" />
                <div class="flex items-center gap-1.5">
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
                    Tom
                  </span>
                  <.camelot_seal value={camelot(@track)} />
                </div>
                <.stat
                  :if={@track.loudness_lufs}
                  label="Ganho recomendado"
                  value={format_gain(Loudness.gain_db(@track.loudness_lufs, @track.true_peak_dbtp))}
                />
                <.confidence_chip level={@track.sc_match_confidence} />
              </div>
            </div>

            <div
              :if={not needs_recovery?(@track)}
              class="col-span-2 flex flex-wrap items-center gap-3 md:col-span-1 md:flex-col md:items-end md:justify-self-end"
            >
              <button
                id="play-track"
                type="button"
                phx-click={
                  toggle_track(%{src: ~p"/audio/#{@track.id}", id: @track.id, preview: false})
                }
                class="inline-flex items-center justify-center gap-2 rounded-full bg-primary-deep px-4 py-2 text-[13px] font-semibold text-white hover:bg-primary-deep/90"
                title="Tocar no player global"
              >
                <.vinyl :if={@track.id == @playing_track_id} size={17} />
                <.icon :if={@track.id != @playing_track_id} name="hero-play-mini" class="size-4" />
                {if @track.id == @playing_track_id, do: "Tocar / pausar", else: "Tocar faixa"}
              </button>
              <.link
                id="track-use-in-set"
                navigate={@planner.path}
                class="inline-flex min-h-11 items-center gap-1.5 rounded-md px-2 text-body-sm font-semibold text-primary-soft hover:bg-white/5 hover:underline"
              >
                <.icon name="hero-queue-list-mini" class="size-4 shrink-0" />
                {@planner.label}
              </.link>
            </div>
          </div>

          <div
            :if={needs_recovery?(@track)}
            class="mt-3 flex flex-wrap items-center gap-2 border-t border-white/6 pt-3 text-body-sm"
          >
            <span class="text-amber">{file_status(@track)}</span>
            <.link
              navigate={~p"/resgate" <> "#arquivo-#{@track.id}"}
              class="text-primary hover:underline"
            >
              Ver recuperação do arquivo
            </.link>
          </div>

          <.link
            :if={is_binary((@track.raw_tags || %{})["recorte_mix_id"])}
            navigate={~p"/sets-online/#{@track.raw_tags["recorte_mix_id"]}"}
            class="mt-3 inline-block text-body-sm text-primary hover:underline"
          >
            Set de origem: {@track.raw_tags["recorte_mix_title"] || "abrir gravação"}
          </.link>
          <nav
            aria-label="Seções da ficha"
            class="mt-3 space-y-2 border-t border-white/6 pt-3 text-body-sm"
          >
            <div class="grid items-baseline gap-x-3 gap-y-1.5 sm:grid-cols-[5rem_minmax(0,1fr)]">
              <span class="font-semibold text-ink-muted">Preparar</span>
              <div class="flex min-w-0 flex-wrap items-baseline gap-x-4 gap-y-1.5">
                <a href="#track-edit" class="text-ink-secondary hover:text-ink hover:underline">Editar faixa</a>
                <a href="#track-curation" class="text-ink-secondary hover:text-ink hover:underline">Nota e tags</a>
                <a href="#track-markers" class="text-ink-secondary hover:text-ink hover:underline">Marcadores</a>
                <a href="#track-loudness" class="text-ink-secondary hover:text-ink hover:underline">Volume</a>
              </div>
            </div>
            <div class="grid items-baseline gap-x-3 gap-y-1.5 sm:grid-cols-[5rem_minmax(0,1fr)]">
              <span class="font-semibold text-ink-muted">Consultar</span>
              <div class="flex min-w-0 flex-wrap items-baseline gap-x-4 gap-y-1.5">
                <a href="#track-analysis" class="text-ink-secondary hover:text-ink hover:underline">Análise</a>
                <a href="#track-origin" class="text-ink-secondary hover:text-ink hover:underline">Origem</a>
                <a href="#track-versions" class="text-ink-secondary hover:text-ink hover:underline">Versões</a>
                <a href="#track-next" class="text-ink-secondary hover:text-ink hover:underline">Próxima faixa</a>
                <a href="#track-matches" class="text-ink-secondary hover:text-ink hover:underline">Parecidas (IA)</a>
              </div>
            </div>
          </nav>
        </header>

        <div class="mt-4 grid grid-cols-1 items-start gap-4 lg:grid-cols-[minmax(0,1.05fr)_minmax(340px,0.95fr)] xl:grid-cols-[minmax(0,1fr)_380px]">
          <div class="min-w-0 space-y-4">
            <section
              id="track-edit"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <.section_label major>Editar faixa</.section_label>
              <p class="mt-1 text-body-sm text-ink-muted">Use o lápis para corrigir um campo.</p>
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
                  label="Tag de gênero"
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
              </div>
              <div class="mt-4 border-t border-white/6 pt-3">
                <.section_label>Arquivo no disco</.section_label>
                <.editable_row
                  field={:filename}
                  label="Nome"
                  value={@track.filename}
                  display={@track.filename}
                  editing={@editing_field}
                />
                <div class="mt-2 flex flex-wrap items-center justify-between gap-2">
                  <form
                    id="track-folder"
                    phx-change="change_folder"
                    class="flex min-w-0 flex-wrap items-center gap-2"
                  >
                    <label for="track-folder-select" class="text-body-sm text-ink-secondary">
                      Mover para outra pasta
                    </label>
                    <select
                      id="track-folder-select"
                      name="folder"
                      class="h-8 min-w-0 max-w-full rounded-md border border-white/10 bg-input px-2 py-1 text-body-sm text-ink focus:border-primary/50 sm:max-w-48"
                      title="Mover a faixa para outra pasta (move o arquivo no disco)"
                    >
                      <option :if={is_nil(@track.genre_folder)} value="" selected>
                        — sem pasta —
                      </option>
                      <option
                        :for={f <- @folders}
                        value={f.key}
                        selected={f.key == @track.genre_folder}
                      >
                        {f.display_name}
                      </option>
                    </select>
                  </form>
                  <button
                    phx-click="delete_track"
                    data-confirm="Apagar esta faixa de vez? O arquivo sai do disco e não tem volta."
                    class="rounded-md border border-coral/40 px-2.5 py-1 text-[11px] font-semibold text-coral hover:bg-coral/10"
                    title="Apagar faixa"
                  >
                    Apagar faixa
                  </button>
                </div>
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
              id="track-curation"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <.section_label major>Minha nota e tags</.section_label>
              <div class="mt-3"><.rating_control value={@track.rating} /></div>

              <div class="mt-4 border-t border-white/6 pt-3">
                <.section_label>Minhas tags</.section_label>
                <div class="mt-2 flex flex-wrap gap-1.5">
                  <span
                    :for={tag <- @track.tags || []}
                    class="inline-flex min-w-0 max-w-full items-center gap-1 rounded-sm border border-primary/40 bg-primary/15 px-2 py-1 text-[11px] text-ink"
                  >
                    <span class="min-w-0 break-words [overflow-wrap:anywhere]">{tag}</span>
                    <button
                      phx-click="remove_tag"
                      phx-value-tag={tag}
                      aria-label={"Remover tag #{tag}"}
                      class="shrink-0 text-ink-muted hover:text-coral"
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
                    aria-label="Nova tag"
                    placeholder="+ nova tag"
                    class="min-w-0 flex-1 rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm focus:border-primary/50"
                  />
                  <datalist id="tag-suggestions">
                    <option :for={t <- @all_tags} value={t} />
                  </datalist>
                  <button class="rounded-md bg-primary-deep px-3 py-1.5 text-body-sm font-semibold text-white">Adicionar</button>
                </form>
              </div>

              <form id="track-note" phx-change="save_note" class="mt-4 border-t border-white/6 pt-3">
                <.section_label>Anotação pessoal</.section_label>
                <textarea
                  name="note"
                  rows="3"
                  phx-debounce="600"
                  aria-label="Anotação pessoal"
                  placeholder="Observações suas sobre a faixa…"
                  class="mt-2 w-full resize-none rounded-md border border-white/8 bg-input px-3 py-2 text-body-sm focus:border-primary/50"
                >{@track.personal_note}</textarea>
              </form>
            </section>
          </div>
          <div class="min-w-0 space-y-4">
            <section
              id="track-markers"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-3">
                <.section_label major>Marcadores</.section_label>
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    phx-click="detect_markers"
                    class="rounded-md border border-white/10 bg-input px-2.5 py-1 text-[11px] text-ink-secondary hover:text-ink"
                    title="Detectar intro/saída automaticamente por análise de áudio"
                  >
                    Detectar
                  </button>
                  <button
                    id="track-add-marker"
                    type="button"
                    data-track-id={@track.id}
                    phx-click={
                      JS.dispatch("beatgrid:add-marker",
                        to: "#player-audio",
                        detail: %{track_id: @track.id}
                      )
                    }
                    disabled
                    aria-describedby="track-add-marker-help"
                    class="rounded-md border border-amber/40 bg-amber/10 px-2.5 py-1 text-[11px] font-semibold text-amber hover:bg-amber/20 disabled:cursor-not-allowed disabled:opacity-40"
                    title="Toque esta faixa antes de adicionar um marcador"
                  >
                    Adicionar marcador
                  </button>
                </div>
              </div>
              <p id="track-add-marker-help" class="mt-2 text-body-sm text-ink-muted">
                Toque esta faixa no player desta aba e avance até a posição do marcador.
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

            <section
              id="track-loudness"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <div class="flex items-center justify-between gap-3">
                <.section_label major>Volume (loudness)</.section_label>
                <span class="text-caption text-ink-faint">
                  Alvo {format_lufs(Loudness.target_lufs())}
                </span>
              </div>

              <dl
                :if={@track.loudness_lufs}
                class="mt-3 grid grid-cols-[7rem_minmax(0,1fr)] items-baseline gap-x-3 gap-y-2 text-body-sm"
              >
                <dt class="text-ink-faint">Arquivo atual</dt>
                <dd class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
                  <span class="text-amber font-mono">{format_lufs(@track.loudness_lufs)}</span>
                  <span :if={@track.true_peak_dbtp} class="text-ink-secondary font-mono">
                    {Float.round(@track.true_peak_dbtp, 1)} dBTP
                  </span>
                </dd>
                <dt class="text-ink-faint">Ganho recomendado</dt>
                <dd class="font-mono text-primary">
                  {format_gain(Loudness.gain_db(@track.loudness_lufs, @track.true_peak_dbtp))}
                </dd>

                <dt :if={@track.original_loudness_lufs} class="text-ink-faint">Backup original</dt>
                <dd
                  :if={@track.original_loudness_lufs}
                  class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1"
                >
                  <span class="font-mono text-ink-secondary">
                    {format_lufs(@track.original_loudness_lufs)}
                  </span>
                  <span :if={@track.original_true_peak_dbtp} class="font-mono text-ink-muted">
                    {Float.round(@track.original_true_peak_dbtp, 1)} dBTP
                  </span>
                </dd>

                <dt :if={@track.gain_applied_at} class="text-ink-faint">Ganho aplicado</dt>
                <dd
                  :if={@track.gain_applied_at}
                  class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1"
                >
                  <span class="font-mono text-primary">{format_gain(@track.gain_applied_db)}</span>
                  <span class="text-ink-muted">{if @gain_backup,
                    do: "Backup original registrado",
                    else: "Sem backup original registrado"}</span>
                </dd>
              </dl>

              <p :if={!@track.loudness_lufs} class="text-ink-faint mt-3 text-caption">
                Loudness ainda não medido.
                <.link
                  navigate={~p"/manutencao" <> "#maintenance-loudness"}
                  class="text-primary hover:underline"
                >
                  Medir loudness em Manutenção
                </.link>
              </p>

              <div :if={@gain_backup} class="mt-3 flex flex-wrap gap-2">
                <button
                  type="button"
                  phx-click={
                    JS.dispatch("beatgrid:play",
                      to: "#player-audio",
                      detail: %{src: ~p"/audio/#{@track.id}/original", id: @track.id, preview: true}
                    )
                  }
                  class="inline-flex items-center justify-center gap-2 rounded-md border border-primary/35 bg-primary/10 px-3 py-2 text-[12px] font-semibold text-primary hover:bg-primary/20"
                >
                  <span aria-hidden="true">▶</span> Tocar original
                </button>
                <button
                  type="button"
                  phx-click="restore_gain_backup"
                  data-confirm="Restaurar o backup original (pré-ganho) por cima do arquivo atual?"
                  class="inline-flex items-center justify-center rounded-md border border-amber/35 bg-amber/10 px-3 py-2 text-[12px] font-semibold text-amber hover:bg-amber/20"
                >
                  Restaurar backup original
                </button>
              </div>
            </section>
          </div>
        </div>

        <div class="mt-4 grid grid-cols-1 items-start gap-4 lg:grid-cols-[minmax(0,1.05fr)_minmax(340px,0.95fr)] xl:grid-cols-[minmax(0,1fr)_380px]">
          <div class="min-w-0 space-y-4">
            <section
              id="track-analysis"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <.section_label major>Análise de BPM e tom</.section_label>
                <button
                  phx-click="reanalyze"
                  disabled={@analyzing?}
                  class="rounded-md border border-white/10 bg-input px-2.5 py-1 text-[11px] text-ink-secondary hover:text-ink disabled:opacity-50"
                >
                  {if @analyzing?, do: "Analisando…", else: "Reanalisar áudio local"}
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
                Os BPMs divergem bastante (possível erro de dobro/metade) — confira ouvindo na onda.
              </p>
            </section>

            <section
              id="track-origin"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <.section_label major>Metadados de origem</.section_label>
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    phx-click="enrich_track"
                    data-confirm="Atualizar metadados consulta o Soundcharts (gasta cota). Continuar?"
                    disabled={@enriching? or not Beatgrid.Integrations.configured?(:soundcharts)}
                    class="rounded-md border border-primary/40 bg-primary/10 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/20 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {if @enriching?, do: "Atualizando…", else: "Atualizar metadados"}
                  </button>
                  <.integration_gate key={:soundcharts} />
                </div>
              </div>
              <dl class="mt-3 space-y-1.5">
                <div
                  :for={{k, v} <- meta_rows(@track)}
                  class="flex justify-between gap-4 text-body-sm"
                >
                  <dt class="text-ink-faint">{k}</dt>
                  <dd class="min-w-0 break-words text-right text-ink-secondary">{v}</dd>
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
          </div>
          <div class="min-w-0 space-y-4">
            <section
              id="track-versions"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <div class="flex items-center justify-between gap-3">
                <.section_label major>
                  Outras versões desta música ({length(@versions)})
                </.section_label>
              </div>
              <ul :if={@versions != []} class="mt-2 divide-y divide-white/4">
                <li :for={v <- @versions} class="flex min-w-0 items-center gap-3 py-2">
                  <button
                    type="button"
                    phx-click={
                      JS.dispatch("beatgrid:play",
                        to: "#player-audio",
                        detail: %{src: ~p"/audio/#{v.id}", id: v.id, preview: true}
                      )
                    }
                    class="flex size-8 shrink-0 items-center justify-center rounded-full border border-primary/30 bg-primary/10 text-[12px] text-primary hover:bg-primary/20"
                    title="Ouvir esta versão"
                  >
                    ▶
                  </button>
                  <div class="min-w-0 flex-1">
                    <.link
                      navigate={~p"/track/#{v.id}?#{@origin.params}"}
                      class="block truncate text-body-sm font-medium text-ink hover:text-primary hover:underline"
                    >
                      {title(v)}
                    </.link>
                    <p class="truncate text-caption text-ink-muted">{v.tag_artist || "—"}</p>
                  </div>
                  <span
                    :if={ver_label(v)}
                    class="hidden shrink-0 rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] uppercase tracking-wide text-ink-muted sm:inline-flex"
                  >
                    {ver_label(v)}
                  </span>
                  <.camelot_seal value={camelot(v)} />
                  <span class="hidden w-10 shrink-0 text-right font-mono text-[11px] text-primary sm:inline">
                    {bpm(v)}
                  </span>
                  <span
                    :if={v.loudness_lufs}
                    class="hidden shrink-0 font-mono text-[11px] text-ink-muted md:inline"
                  >
                    {format_lufs(v.loudness_lufs)}
                  </span>
                </li>
              </ul>
              <p :if={@versions == []} class="mt-3 text-body-sm text-ink-faint">
                Nenhuma outra versão encontrada.
              </p>
            </section>

            <section
              id="track-next"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <.section_label major>Próxima faixa compatível (harmônica)</.section_label>
              <div :if={@next != []} class="mt-3 space-y-1">
                <.link
                  :for={s <- @next}
                  navigate={~p"/track/#{s.track.id}?#{@origin.params}"}
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

            <section
              id="track-matches"
              class="min-w-0 scroll-mt-4 rounded-xl border border-white/6 bg-surface p-4"
            >
              <div class="flex flex-wrap items-start justify-between gap-x-3 gap-y-2">
                <div class="min-w-0 flex-1 basis-48">
                  <.section_label major>Sugestões parecidas (IA)</.section_label>
                  <p class="mt-1 text-caption text-ink-faint">
                    Faixas de outra origem que combinam com esta — mesmo clima, época e energia.
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="fetch_matches"
                  disabled={@recommending?}
                  class="inline-flex shrink-0 items-center gap-2 rounded-md bg-primary-deep px-3 py-1.5 text-[12px] font-semibold text-white transition-opacity disabled:opacity-50"
                >
                  <span
                    :if={@recommending?}
                    class="size-2 motion-safe:animate-pulse rounded-full bg-white/90"
                    aria-hidden="true"
                  ></span>
                  {if @recommending?, do: "Gerando…", else: "Buscar parecidas"}
                </button>
              </div>

              <div :if={@pending_recs != []} id="track-matches-pending" class="mt-3 space-y-1.5">
                <.rec_row :for={rec <- @pending_recs} rec={rec} />
              </div>

              <details
                :if={@imported_recs != []}
                id="track-matches-imported"
                class="mt-4 border-t border-white/8 pt-3"
              >
                <summary class="cursor-pointer rounded-md py-2 text-body-lg font-semibold text-ink-secondary hover:text-ink">
                  Já importadas
                  <span class="font-mono text-body font-normal text-ink-muted">({length(
                    @imported_recs
                  )})</span>
                </summary>
                <div class="mt-2 space-y-1.5">
                  <.rec_row :for={rec <- @imported_recs} rec={rec} />
                </div>
              </details>

              <div
                :if={@recs == [] and @recommending?}
                class="mt-3 flex items-center gap-2 rounded-lg border border-primary/25 bg-primary/8 px-3 py-3 text-body-sm text-ink-secondary"
              >
                <span
                  class="size-2.5 motion-safe:animate-pulse rounded-full bg-primary"
                  aria-hidden="true"
                ></span>
                Gerando sugestões com a IA… isso pode levar alguns segundos.
              </div>

              <p
                :if={@recs == [] and not @recommending?}
                class="mt-3 text-body-sm text-ink-faint"
              >
                Nenhuma sugestão salva para esta faixa. Clique em <span class="text-ink-secondary">Buscar parecidas</span>.
              </p>
            </section>
          </div>
        </div>
      </div>
    </.app_shell>
    """
  end

  attr :track, :map, required: true

  defp track_gold_toggle(assigns) do
    {gold?, _reason} = Beatgrid.Gold.effective(assigns.track)
    assigns = assign(assigns, gold?: gold?)

    ~H"""
    <button
      type="button"
      phx-click="toggle_gold"
      aria-pressed={if @gold?, do: "true", else: "false"}
      class={[
        "inline-flex shrink-0 items-center gap-1.5 rounded-md border px-2 py-1 text-body-sm font-semibold focus-visible:outline-primary",
        @gold? && "border-amber/40 text-amber",
        not @gold? && "border-white/10 bg-input text-ink-secondary hover:text-ink"
      ]}
    >
      <span aria-hidden="true">
        <.ouro_badge :if={@gold?} track={@track} />
        <span :if={not @gold?} class="hero-star size-3.5" />
      </span>
      Ouro
    </button>
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
    <div class="grid grid-cols-[5rem_minmax(0,1fr)] items-center gap-x-2 gap-y-1.5 py-1.5">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        {@label}
      </span>
      <form
        :if={@editing == @field}
        phx-submit="save_field"
        class="col-span-2 flex min-w-0 items-center gap-1.5 sm:col-span-1"
      >
        <input type="hidden" name="field" value={@field} />
        <input
          type={@type}
          name="value"
          value={@value}
          aria-label={@label}
          placeholder={@placeholder}
          phx-mounted={JS.focus()}
          phx-keydown="cancel_edit"
          phx-key="Escape"
          class="min-w-0 flex-1 rounded-md border border-primary/50 bg-input px-2 py-1 text-body-sm"
        />
        <button
          type="submit"
          class="rounded-md px-2 py-1 text-body-sm font-semibold text-green hover:bg-green/10"
          aria-label={"Salvar #{@label}"}
        >Salvar</button>
        <button
          type="button"
          phx-click="cancel_edit"
          class="rounded-md px-2 py-1 text-body-sm text-ink-muted hover:text-ink"
          aria-label={"Cancelar #{@label}"}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </form>
      <span :if={@editing != @field} class="flex min-w-0 items-center gap-1.5">
        <span class={[
          "min-w-0 break-words text-body-sm [overflow-wrap:anywhere]",
          @display in [nil, ""] && "text-ink-faint"
        ]}>
          {(@display in [nil, ""] && "—") || @display}
        </span>
        <span :if={@edited?} class="shrink-0 text-[11px] text-primary" title="editado manualmente">
          •
        </span>
        <button
          type="button"
          phx-click="edit_field"
          phx-value-field={@field}
          class="ml-auto inline-flex size-8 shrink-0 items-center justify-center rounded-md text-ink-muted hover:bg-surface-2 hover:text-ink focus-visible:outline-primary"
          aria-label={"Editar #{@label}"}
          title={"Editar #{@label}"}
        >
          <span class="hero-pencil-square size-4" aria-hidden="true" />
        </button>
      </span>
    </div>
    """
  end

  attr :major, :boolean, default: false
  slot :inner_block, required: true

  defp section_label(assigns) do
    ~H"""
    <h2 :if={@major} class="text-[18px] font-semibold leading-tight text-ink">
      {render_slot(@inner_block)}
    </h2>
    <h3 :if={!@major} class="text-caption font-semibold uppercase tracking-wider text-ink-muted">
      {render_slot(@inner_block)}
    </h3>
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

  defp bpm(track), do: effective_bpm(track)
  defp camelot(track), do: effective_camelot(track)

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
      <button
        phx-click="dismiss_toast"
        aria-label="Fechar aviso"
        class="text-ink-muted hover:text-ink text-body-sm"
      >✕</button>
    </div>
    """
  end

  defp enrich_toast_message({:ok, msg}), do: msg
  defp enrich_toast_message({:error, msg}), do: msg
end
