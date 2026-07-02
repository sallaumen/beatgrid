defmodule BeatgridWeb.LibraryLive do
  @moduledoc "Biblioteca — the filterable track table."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library
  alias Beatgrid.Library.{GenreFolders, TrackQuery, Tracks}
  alias Beatgrid.Loudness
  alias Beatgrid.Operations
  alias Beatgrid.Playback
  alias Beatgrid.Soundcharts.Camelot
  alias Beatgrid.Workers.ImportWorker

  # "Parecidas" widens the energy window by ±this many points (0–100) around the
  # reference track's effective energy.
  @energy_window 12

  @confidences [{"alta", :high}, {"média", :medium}, {"baixa", :low}]

  # Rows loaded per DB page; the rest stream in on scroll (no load-everything query).
  @per_page 100

  # Camelot wheel geometry, computed once. Two concentric rings (A inner / B outer),
  # 12 wedges each, number `n` centered at `n*30°` clockwise from the top.
  @wheel_cx 140
  @wheel_cy 140

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Library.subscribe_import()
      Playback.subscribe()
    end

    np = Playback.now_playing()

    {:ok,
     socket
     |> assign(
       page_title: "Biblioteca",
       folders: GenreFolders.list(),
       filters: %{},
       sort: {:artist, :asc},
       selecting?: false,
       selected: MapSet.new(),
       row_menu: nil,
       tom_wheel_open: false,
       move_toast: nil,
       import: nil,
       import_progress: nil,
       import_toast: nil,
       playing_track_id: np.track_id,
       all_tags: Tracks.all_tags()
     )
     |> load_tracks()}
  end

  @impl true
  def handle_event("toggle_genre", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> update_filter(:genre_folder, toggle(socket.assigns.filters[:genre_folder], key))
     |> load_tracks()}
  end

  def handle_event("toggle_confidence", %{"level" => level}, socket) do
    {:noreply,
     socket
     |> update_filter(:confidence, toggle(socket.assigns.filters[:confidence], level))
     |> load_tracks()}
  end

  def handle_event("toggle_unclassified", _params, socket) do
    {:noreply,
     socket
     |> update_filter(:unclassified, toggle(socket.assigns.filters[:unclassified], true))
     |> load_tracks()}
  end

  def handle_event("toggle_tag", %{"tag" => tag}, socket) do
    {:noreply,
     socket
     |> update_filter(:tag, toggle(socket.assigns.filters[:tag], tag))
     |> load_tracks()}
  end

  # Clicking a column header sorts by that field — toggling asc/desc when it's
  # already the active field, otherwise starting ascending.
  def handle_event("sort", %{"by" => by}, socket) do
    field = String.to_existing_atom(by)
    {cur_field, cur_dir} = socket.assigns.sort
    dir = if cur_field == field, do: flip_dir(cur_dir), else: :asc

    {:noreply, socket |> assign(sort: {field, dir}) |> load_tracks()}
  end

  def handle_event("filter", params, socket) do
    filters =
      socket.assigns.filters
      |> put_filter(:search, params["search"])
      |> put_filter(:rating_min, params["rating_min"])
      |> put_filter(:rating_max, params["rating_max"])
      |> put_filter(:bpm_min, params["bpm_min"])
      |> put_filter(:bpm_max, params["bpm_max"])
      |> put_filter(:energy_min, params["energy_min"])
      |> put_filter(:energy_max, params["energy_max"])

    # `camelot` / `camelot_compatible` are managed by the Tom wheel popover
    # (set_camelot / toggle_camelot_compatible), not this form.
    {:noreply, socket |> assign(filters: filters) |> load_tracks()}
  end

  def handle_event("toggle_tom_wheel", _params, socket),
    do: {:noreply, assign(socket, tom_wheel_open: not socket.assigns.tom_wheel_open)}

  def handle_event("close_tom_wheel", _params, socket),
    do: {:noreply, assign(socket, tom_wheel_open: false)}

  # Click a wedge: set that Camelot code as the filter; clicking the active one
  # (or the empty "limpar") clears it. Results refresh live behind the popover.
  def handle_event("set_camelot", %{"code" => code}, socket) do
    value = if code in ["", socket.assigns.filters[:camelot]], do: nil, else: code
    {:noreply, socket |> update_filter(:camelot, value) |> load_tracks()}
  end

  def handle_event("toggle_camelot_compatible", _params, socket) do
    value = if socket.assigns.filters[:camelot_compatible] == true, do: nil, else: true
    {:noreply, socket |> update_filter(:camelot_compatible, value) |> load_tracks()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(filters: %{}) |> load_tracks()}
  end

  def handle_event("toggle_gold_filter", _params, socket) do
    current = socket.assigns.filters[:gold]
    {:noreply, socket |> update_filter(:gold, if(current, do: nil, else: true)) |> load_tracks()}
  end

  # --- per-row ⋯ menu ---

  def handle_event("row_menu_toggle", %{"id" => id}, socket) do
    {:noreply, assign(socket, row_menu: toggle(socket.assigns.row_menu, id))}
  end

  def handle_event("close_row_menu", _params, socket),
    do: {:noreply, assign(socket, row_menu: nil)}

  def handle_event("move_track", %{"track_id" => id, "to" => folder_key}, socket) do
    socket = assign(socket, row_menu: nil)

    case Tracks.get(id) do
      nil ->
        {:noreply, socket}

      track ->
        case Library.move_to_folder(track, folder_key) do
          {:ok, _moved, batch_id} ->
            {:noreply, socket |> assign(move_toast: {:moved, 1, batch_id}) |> load_tracks()}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  # "Parecidas": reuse the screen by pre-filling filters around the track —
  # compatible key, an energy window, and the same folder.
  def handle_event("similar_to", %{"track_id" => id}, socket) do
    socket = assign(socket, row_menu: nil)

    case Tracks.get_with_song(id) do
      nil -> {:noreply, socket}
      track -> {:noreply, socket |> assign(filters: similar_filters(track)) |> load_tracks()}
    end
  end

  # --- discrete batch select mode ---

  def handle_event("toggle_select_mode", _params, socket) do
    selecting? = not socket.assigns.selecting?
    # leaving select mode clears the pending selection
    selected = if selecting?, do: socket.assigns.selected, else: MapSet.new()
    {:noreply, assign(socket, selecting?: selecting?, selected: selected, row_menu: nil)}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, id) do
        MapSet.delete(socket.assigns.selected, id)
      else
        MapSet.put(socket.assigns.selected, id)
      end

    {:noreply, assign(socket, selected: selected)}
  end

  # Scroll reached the bottom — append the next DB page (guarded so it no-ops once
  # everything matching the filters is loaded). Events are processed sequentially,
  # so a rapid double-fire just loads consecutive pages, never duplicates.
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more? do
      page = socket.assigns.page + 1

      more =
        TrackQuery.library(
          Map.merge(base_filters(socket), %{limit: @per_page, offset: (page - 1) * @per_page})
        )

      tracks = socket.assigns.tracks ++ more

      {:noreply,
       assign(socket,
         tracks: tracks,
         page: page,
         has_more?: length(tracks) < socket.assigns.total
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_all", _params, socket) do
    # All ids matching the current filters (across every page), not just the loaded rows.
    selected = MapSet.new(TrackQuery.library_ids(base_filters(socket)))
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, assign(socket, selected: MapSet.new())}

  def handle_event("move_selected", %{"folder" => folder_key}, socket)
      when folder_key not in [nil, ""] do
    ids = MapSet.to_list(socket.assigns.selected)
    %{moved: moved, batch_id: batch_id} = Library.move_many(ids, folder_key)

    {:noreply,
     socket
     |> assign(move_toast: {:moved, moved, batch_id}, selected: MapSet.new())
     |> load_tracks()}
  end

  def handle_event("move_selected", _params, socket), do: {:noreply, socket}

  def handle_event("rate_selected", %{"rating" => rating}, socket) do
    n = String.to_integer(rating)

    Enum.each(socket.assigns.selected, fn id ->
      case Tracks.get(id) do
        nil -> :ok
        track -> Tracks.update(track, %{rating: n})
      end
    end)

    {:noreply, socket |> load_tracks()}
  end

  def handle_event("undo_move", _params, socket) do
    case socket.assigns.move_toast do
      {:moved, _n, batch_id} ->
        Operations.undo_batch(batch_id)
        {:noreply, socket |> assign(move_toast: nil) |> load_tracks()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_move_toast", _params, socket),
    do: {:noreply, assign(socket, move_toast: nil)}

  # --- import: open/close the modal ---

  def handle_event("show_import", _params, socket),
    do: {:noreply, assign(socket, import: %{open: true})}

  def handle_event("hide_import", _params, socket), do: {:noreply, assign(socket, import: nil)}

  # --- import: read-only enrich-before-import preview (writes nothing) ---

  def handle_event("preview_import", params, socket) do
    source = String.trim(params["source"] || "")
    ai? = params["ai"] == "on"
    soundcharts? = params["soundcharts"] == "on"

    if source == "" do
      {:noreply, assign(socket, import: %{open: true, error: "Cole um caminho."})}
    else
      {:noreply,
       socket
       |> assign(
         import: %{open: true, source: source, ai: ai?, soundcharts: soundcharts?, loading: true}
       )
       |> start_async(:preview, fn -> Library.preview_import(source, ai: ai?) end)}
    end
  end

  # --- import: commit — enqueue the copying ImportWorker with the reviewed overrides ---

  def handle_event("run_import", params, socket) do
    import_state = socket.assigns.import
    items = items_from_params(params, import_state.rows)

    if items == [] do
      {:noreply, socket}
    else
      batch_id = Uniq.UUID.uuid7()

      {:ok, _job} =
        ImportWorker.enqueue(items, batch_id, resolve_soundcharts: import_state.soundcharts)

      {:noreply,
       assign(socket,
         import: nil,
         import_progress: %{batch_id: batch_id, status: :queued, done: 0, total: length(items)}
       )}
    end
  end

  def handle_event("dismiss_import_toast", _params, socket),
    do: {:noreply, assign(socket, import_toast: nil)}

  @impl true
  def handle_async(:preview, {:ok, {:ok, rows}}, socket) do
    state = Map.merge(socket.assigns.import, %{loading: false, rows: rows, error: nil})
    {:noreply, assign(socket, import: state)}
  end

  def handle_async(:preview, {:ok, {:error, :not_found}}, socket) do
    state =
      socket.assigns.import
      |> Map.merge(%{loading: false, rows: nil})
      |> Map.put(:error, "Caminho não encontrado ou não é áudio.")

    {:noreply, assign(socket, import: state)}
  end

  def handle_async(:preview, {:exit, _reason}, socket) do
    state =
      socket.assigns.import
      |> Map.merge(%{loading: false, rows: nil})
      |> Map.put(:error, "Falha ao pré-visualizar.")

    {:noreply, assign(socket, import: state)}
  end

  @impl true
  def handle_info({:import_progress, %{status: :done} = p}, socket) do
    {:noreply,
     socket
     |> assign(import_progress: nil, import_toast: import_summary(p))
     |> load_tracks()}
  end

  def handle_info({:import_progress, p}, socket) do
    {:noreply, assign(socket, import_progress: p)}
  end

  def handle_info({:now_playing, np}, socket) do
    {:noreply, assign(socket, playing_track_id: np.track_id)}
  end

  # Build the Oban-shaped items from the per-row edited inputs. Only NEW rows are
  # importable; duplicates are previewed greyed-out without inputs, so they never
  # appear in `params["items"]` and are dropped here for good measure.
  defp items_from_params(params, rows) do
    edits = params["items"] || %{}
    dupe_paths = rows |> Enum.filter(& &1.duplicate) |> MapSet.new(& &1.source_path)

    edits
    |> Map.values()
    |> Enum.reject(&MapSet.member?(dupe_paths, &1["source_path"]))
    |> Enum.map(fn e ->
      %{
        "source_path" => e["source_path"],
        "artist" => String.trim(e["artist"] || ""),
        "title" => String.trim(e["title"] || "")
      }
    end)
  end

  defp import_summary(%{imported: n}) when n > 0, do: "#{n} faixa(s) importada(s)."
  defp import_summary(_p), do: "Nada novo para importar."

  # Resets to the first page — used after any filter/sort/move change. Loads page 1
  # (100 rows) + the total count so the header and has-more? are accurate.
  defp load_tracks(socket) do
    filters = base_filters(socket)
    total = TrackQuery.count_library(filters)
    tracks = TrackQuery.library(Map.merge(filters, %{limit: @per_page, offset: 0}))

    assign(socket,
      tracks: tracks,
      total: total,
      page: 1,
      has_more?: length(tracks) < total,
      # Recompute the tag chips alongside the rows so newly added/removed tags
      # (here or on the track page) appear/disappear without a full page reload.
      all_tags: Tracks.all_tags()
    )
  end

  defp base_filters(socket), do: Map.put(socket.assigns.filters, :sort, socket.assigns.sort)

  defp update_filter(socket, key, nil),
    do: assign(socket, filters: Map.delete(socket.assigns.filters, key))

  defp update_filter(socket, key, val),
    do: assign(socket, filters: Map.put(socket.assigns.filters, key, val))

  defp toggle(current, val), do: if(current == val, do: nil, else: val)
  defp put_filter(filters, key, val) when val in [nil, ""], do: Map.delete(filters, key)
  defp put_filter(filters, key, val), do: Map.put(filters, key, val)

  defp flip_dir(:asc), do: :desc
  defp flip_dir(:desc), do: :asc

  # Filters that surface tracks "near" the reference: harmonically compatible key,
  # an energy band around its effective energy, and the same folder.
  defp similar_filters(track) do
    eff = Library.effective(track)

    %{}
    |> maybe_put(:camelot, eff.camelot)
    |> maybe_put(:camelot_compatible, eff.camelot && true)
    |> maybe_put(:genre_folder, track.genre_folder)
    |> energy_band(eff.energy)
  end

  defp energy_band(filters, energy) when is_number(energy) do
    center = round(energy * 100)

    filters
    |> Map.put(:energy_min, clamp(center - @energy_window))
    |> Map.put(:energy_max, clamp(center + @energy_window))
  end

  defp energy_band(filters, _energy), do: filters

  defp clamp(n), do: n |> max(0) |> min(100)

  defp maybe_put(filters, _key, nil), do: filters
  defp maybe_put(filters, key, value), do: Map.put(filters, key, value)

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:biblioteca} socket={@socket}>
      <div class="flex h-[calc(100vh_-_5rem)] flex-col">
        <header class="flex items-center justify-between gap-4 border-b border-white/6 bg-rail px-5 py-3">
          <div class="flex items-baseline gap-3">
            <h2 class="text-[22px] font-semibold">Biblioteca</h2>
            <span class="font-mono text-body-sm text-ink-muted">{@total} faixas</span>
            <button
              phx-click="show_import"
              class="rounded-md bg-primary px-3 py-1.5 text-body-sm font-semibold text-white"
            >
              Importar
            </button>
          </div>
          <div class="flex items-center gap-3">
            <.import_progress_bar :if={@import_progress} progress={@import_progress} />
            <%= if @selecting? do %>
              <div class="flex items-center gap-2">
                <button
                  phx-click="select_all"
                  class="rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm text-ink-muted hover:text-ink"
                >
                  Marcar todas
                </button>
                <button
                  phx-click="clear_selection"
                  class="rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm text-ink-muted hover:text-ink"
                >
                  Limpar
                </button>
                <button
                  phx-click="toggle_select_mode"
                  class="rounded-md bg-primary/20 px-2.5 py-1.5 text-body-sm font-semibold text-primary"
                >
                  Concluir
                </button>
              </div>
            <% else %>
              <button
                phx-click="toggle_select_mode"
                class="rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm text-ink-muted hover:text-ink"
              >
                Selecionar
              </button>
            <% end %>
            <form id="library-search" phx-change="filter" class="w-72">
              <input
                type="search"
                name="search"
                value={@filters[:search] || ""}
                placeholder="Buscar artista ou título…"
                class="w-full rounded-md border border-white/8 bg-input px-3 py-1.5 text-body placeholder:text-ink-faint focus:border-primary/50 focus:outline-none"
              />
            </form>
          </div>
        </header>

        <.import_toast :if={@import_toast} message={@import_toast} />
        <.move_toast :if={@move_toast} toast={@move_toast} />

        <div class="relative flex min-h-0 flex-1">
          <aside class="w-60 shrink-0 overflow-y-auto border-r border-white/6 bg-rail px-4 py-4">
            <.filters_panel filters={@filters} folders={@folders} tags={@all_tags} />
          </aside>

          <section id="library-rows" class="min-w-0 flex-1 overflow-y-auto px-5 py-4">
            <.track_table
              :if={@tracks != []}
              tracks={@tracks}
              sort={@sort}
              selecting?={@selecting?}
              selected={@selected}
              row_menu={@row_menu}
              folders={@folders}
              playing_id={@playing_track_id}
            />
            <p
              :if={@has_more?}
              id="library-sentinel"
              phx-hook=".InfiniteScroll"
              phx-click="load_more"
              class="cursor-pointer py-4 text-center font-mono text-[11px] text-ink-faint hover:text-ink-muted"
            >
              carregando mais…
            </p>
            <.empty_state :if={@tracks == []} />
          </section>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".InfiniteScroll">
            export default {
              mounted() {
                const root = this.el.closest("#library-rows");
                this.observer = new IntersectionObserver((entries) => {
                  if (entries.some((e) => e.isIntersecting)) this.pushEvent("load_more", {});
                }, { root, rootMargin: "400px" });
                this.observer.observe(this.el);
              },
              destroyed() {
                if (this.observer) this.observer.disconnect();
              }
            }
          </script>

          <div :if={@tom_wheel_open} class="fixed inset-0 z-20" phx-click="close_tom_wheel" />
          <div
            :if={@tom_wheel_open}
            class="absolute left-[15.5rem] top-3 z-30 w-[324px] rounded-2xl border border-white/10 bg-surface p-4 shadow-lg"
          >
            <div class="mb-1 flex items-center justify-between">
              <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
                Roda harmônica
              </span>
              <button
                phx-click="close_tom_wheel"
                class="text-ink-muted hover:text-ink"
                aria-label="Fechar"
              >
                <span class="hero-x-mark size-4" />
              </button>
            </div>
            <.camelot_wheel
              selected={@filters[:camelot]}
              compatible?={@filters[:camelot_compatible] == true}
            />
            <div class="mt-2 flex items-center justify-between">
              <label class="flex cursor-pointer items-center gap-2 text-[12px] text-ink-muted">
                <input
                  type="checkbox"
                  checked={@filters[:camelot_compatible] == true}
                  phx-click="toggle_camelot_compatible"
                  class="rounded border-white/20 bg-input"
                /> incluir compatíveis
              </label>
              <button
                :if={@filters[:camelot]}
                phx-click="set_camelot"
                phx-value-code=""
                class="text-[12px] text-ink-muted hover:text-ink"
              >
                limpar tom
              </button>
            </div>
          </div>
        </div>

        <.batch_bar
          :if={@selecting? and MapSet.size(@selected) > 0}
          count={MapSet.size(@selected)}
          folders={@folders}
          move_toast={@move_toast}
        />
      </div>

      <.import_modal :if={@import && @import.open} import={@import} />
    </.app_shell>
    """
  end

  attr :filters, :map, required: true
  attr :folders, :list, required: true
  attr :tags, :list, default: []

  defp filters_panel(assigns) do
    assigns = assign(assigns, confidences: @confidences)

    ~H"""
    <div class="flex items-center justify-between">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Filtros</span>
      <button
        :if={@filters != %{}}
        phx-click="clear_filters"
        class="text-[11px] text-ink-muted hover:text-ink"
      >
        Limpar
      </button>
    </div>

    <div class="mt-3 mb-3">
      <button
        phx-click="toggle_gold_filter"
        class={chip_class(@filters[:gold] == true)}
        title="Só faixas Ouro"
      >
        ★ Ouro
      </button>
    </div>

    <div class="mt-4 mb-1.5 flex items-center justify-between">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Pasta</span>
      <button
        phx-click="toggle_unclassified"
        class={[
          "rounded-sm border px-[7px] py-[3px] text-[10px] font-semibold transition-colors",
          @filters[:unclassified] && "border-primary/60 bg-primary/20 text-ink",
          !@filters[:unclassified] && "border-white/8 bg-input text-ink-faint hover:text-ink-muted"
        ]}
      >
        só não classificadas
      </button>
    </div>
    <div class="flex flex-wrap gap-1.5">
      <button
        :for={folder <- @folders}
        phx-click="toggle_genre"
        phx-value-key={folder.key}
        class={chip_class(@filters[:genre_folder] == folder.key)}
        style={
          @filters[:genre_folder] == folder.key &&
            "--c:#{folder_color(folder.key)};color:#eef0f5;background:color-mix(in srgb,#{folder_color(folder.key)} 22%,transparent);border-color:color-mix(in srgb,#{folder_color(folder.key)} 60%,transparent)"
        }
      >
        {folder.display_name}
      </button>
    </div>

    <div :if={@tags != []}>
      <p class="mt-4 mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        Tags
      </p>
      <div class="flex flex-wrap gap-1.5">
        <button
          :for={tag <- @tags}
          phx-click="toggle_tag"
          phx-value-tag={tag}
          class={chip_class(@filters[:tag] == tag)}
        >
          {tag}
        </button>
      </div>
    </div>

    <p class="mt-4 mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
      Confiança
    </p>
    <div class="flex flex-wrap gap-1.5">
      <button
        :for={{label, level} <- @confidences}
        phx-click="toggle_confidence"
        phx-value-level={level}
        class={chip_class(@filters[:confidence] == to_string(level))}
      >
        {label}
      </button>
    </div>

    <div class="mt-4">
      <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Tom</p>
      <button
        type="button"
        phx-click="toggle_tom_wheel"
        class="flex w-full items-center justify-between rounded-md border border-white/8 bg-input px-2 py-1.5 text-body-sm hover:border-primary/50"
      >
        <span class="flex items-center gap-2 font-mono">
          <span
            :if={@filters[:camelot]}
            class="inline-block size-2.5 rounded-full"
            style={"background:#{camelot_dot(@filters[:camelot])}"}
          />
          {@filters[:camelot] || "Qualquer"}
          <span
            :if={@filters[:camelot] && @filters[:camelot_compatible]}
            class="text-[10px] text-ink-faint"
          >
            + comp.
          </span>
        </span>
        <span class="hero-chevron-down size-3.5 text-ink-faint" />
      </button>
    </div>

    <form id="library-filters" phx-change="filter" class="mt-3.5 space-y-3.5">
      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Nota</p>
        <div class="flex items-center gap-1.5">
          <input
            type="number"
            name="rating_min"
            min="0"
            max="10"
            placeholder="min"
            value={@filters[:rating_min]}
            class="w-16 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
          />
          <span class="text-ink-faint">–</span>
          <input
            type="number"
            name="rating_max"
            min="0"
            max="10"
            placeholder="max"
            value={@filters[:rating_max]}
            class="w-16 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
          />
        </div>
      </div>

      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
          Energia
        </p>
        <div class="flex items-center gap-1.5">
          <input
            type="number"
            name="energy_min"
            min="0"
            max="100"
            placeholder="min"
            value={@filters[:energy_min]}
            class="w-16 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
          />
          <span class="text-ink-faint">–</span>
          <input
            type="number"
            name="energy_max"
            min="0"
            max="100"
            placeholder="max"
            value={@filters[:energy_max]}
            class="w-16 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
          />
        </div>
      </div>

      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
          Faixa de BPM
        </p>
        <div class="flex items-center gap-1.5">
          <input
            type="number"
            name="bpm_min"
            placeholder="min"
            value={@filters[:bpm_min]}
            class="w-16 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
          />
          <span class="text-ink-faint">–</span>
          <input
            type="number"
            name="bpm_max"
            placeholder="max"
            value={@filters[:bpm_max]}
            class="w-16 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
          />
        </div>
      </div>
    </form>
    """
  end

  attr :tracks, :list, required: true
  attr :sort, :any, required: true
  attr :selecting?, :boolean, required: true
  attr :selected, :any, required: true
  attr :row_menu, :string, required: true
  attr :folders, :list, required: true
  attr :playing_id, :string, default: nil

  defp track_table(assigns) do
    ~H"""
    <div class="space-y-1">
      <div
        class="grid items-center gap-2 px-1.5 pb-2 text-[10px] font-semibold uppercase tracking-wider text-ink-faint"
        style={grid_cols(@selecting?)}
      >
        <span :if={@selecting?}></span>
        <span></span>
        <.sort_header field={:artist} label="Faixa" sort={@sort} />
        <.sort_header field={:folder} label="Pasta" sort={@sort} />
        <.sort_header field={:bpm} label="BPM" sort={@sort} align="right" />
        <.sort_header field={:key} label="Tom" sort={@sort} />
        <.sort_header field={:energy} label="Energia" sort={@sort} />
        <.sort_header field={:rating} label="Nota" sort={@sort} align="right" />
        <.sort_header field={:loudness} label="Vol." sort={@sort} align="right" />
        <.sort_header field={:confidence} label="Sinal" sort={@sort} align="right" />
        <span></span>
      </div>
      <div
        :for={track <- @tracks}
        class={[
          "grid items-center gap-2 rounded-lg px-1.5 py-1.5",
          cond do
            track.id == @playing_id -> "bg-primary/15 ring-1 ring-primary/40"
            row_selected?(@selected, track.id) -> "bg-primary/10"
            true -> "hover:bg-surface-2"
          end
        ]}
        style={grid_cols(@selecting?)}
      >
        <button
          :if={@selecting?}
          type="button"
          phx-click="toggle_select"
          phx-value-id={track.id}
          aria-pressed={to_string(row_selected?(@selected, track.id))}
          class="flex items-center justify-center"
          title="Selecionar"
        >
          <span class={[
            "flex size-[18px] items-center justify-center rounded-[5px] border text-[11px] leading-none transition-colors",
            row_selected?(@selected, track.id) && "border-primary bg-primary text-white",
            !row_selected?(@selected, track.id) && "border-white/20 hover:border-white/40"
          ]}>
            <span :if={row_selected?(@selected, track.id)}>✓</span>
          </span>
        </button>
        <.cover_play
          src={cover_src(track)}
          artist={track.tag_artist}
          size={38}
          play_src={~p"/audio/#{track.id}"}
          track_id={track.id}
          preview={true}
          playing?={track.id == @playing_id}
        />
        <div class="min-w-0">
          <div class="flex min-w-0 items-center gap-1.5">
            <.link
              navigate={~p"/track/#{track.id}"}
              class="truncate text-body font-medium text-ink hover:text-primary hover:underline"
            >
              {track.tag_title || track.filename}
            </.link>
            <.ouro_badge track={track} />
          </div>
          <p class="truncate text-caption text-ink-muted">{track.tag_artist || "—"}</p>
        </div>
        <div><.folder_badge :if={track.genre_folder} folder={track.genre_folder} /></div>
        <span class="text-right font-mono text-body text-primary">{bpm(track)}</span>
        <.camelot_seal value={camelot(track)} />
        <div class="h-[5px] w-full rounded-full bg-white/5">
          <div class="h-full rounded-full bg-green" style={"width:#{energy_pct(track)}%"} />
        </div>
        <div class="text-right"><.rating_badge value={track.rating} /></div>
        <div class="text-right">
          <span
            :if={track.loudness_lufs}
            class="text-ink-secondary font-mono text-caption"
            title={format_lufs(track.loudness_lufs)}
          >
            {format_gain(Loudness.gain_db(track.loudness_lufs, track.true_peak_dbtp))}
          </span>
          <span :if={!track.loudness_lufs} class="text-ink-faint text-caption">–</span>
        </div>
        <div class="text-right"><.confidence_chip level={track.sc_match_confidence} /></div>
        <.row_menu track={track} open?={@row_menu == track.id} folders={@folders} />
      </div>
    </div>
    """
  end

  # The per-row ⋯ popover: move-to-folder, "Parecidas", and open. A full-screen
  # backdrop (rendered only when open) closes it on an outside click.
  attr :track, :map, required: true
  attr :open?, :boolean, required: true
  attr :folders, :list, required: true

  defp row_menu(assigns) do
    ~H"""
    <div class="relative flex justify-end">
      <button
        type="button"
        phx-click="row_menu_toggle"
        phx-value-id={@track.id}
        aria-haspopup="true"
        aria-expanded={to_string(@open?)}
        class={[
          "flex size-7 items-center justify-center rounded-md text-[15px] leading-none transition-colors",
          @open? && "bg-white/10 text-ink",
          !@open? && "text-ink-muted hover:bg-white/8 hover:text-ink"
        ]}
        title="Ações"
        aria-label="Ações"
      >
        ⋯
      </button>
      <%= if @open? do %>
        <div class="fixed inset-0 z-30" phx-click="close_row_menu" aria-hidden="true"></div>
        <div class="absolute right-0 top-8 z-40 w-52 overflow-hidden rounded-lg border border-white/10 bg-surface py-1 shadow-xl shadow-black/40">
          <p class="px-3 pt-1.5 pb-1 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
            Mover para
          </p>
          <button
            :for={folder <- @folders}
            :if={folder.key != @track.genre_folder}
            type="button"
            phx-click="move_track"
            phx-value-track_id={@track.id}
            phx-value-to={folder.key}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-body-sm text-ink-secondary hover:bg-white/6 hover:text-ink"
          >
            <span
              class="size-2 shrink-0 rounded-full"
              style={"background:#{folder_color(folder.key)}"}
            />
            {folder.display_name}
          </button>
          <div class="my-1 border-t border-white/8"></div>
          <button
            type="button"
            phx-click="similar_to"
            phx-value-track_id={@track.id}
            class="flex w-full items-center px-3 py-1.5 text-left text-body-sm text-ink-secondary hover:bg-white/6 hover:text-ink"
          >
            Parecidas
          </button>
          <.link
            navigate={~p"/track/#{@track.id}"}
            class="flex w-full items-center px-3 py-1.5 text-body-sm text-ink-secondary hover:bg-white/6 hover:text-ink"
          >
            Abrir
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  # A clickable column header. The active column shows its direction arrow and
  # brightens; the rest reveal a faint ↕ affordance on hover.
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort, :any, required: true
  attr :align, :string, default: "left"

  defp sort_header(assigns) do
    {active_field, dir} = assigns.sort
    active? = active_field == assigns.field

    assigns =
      assign(assigns,
        active?: active?,
        arrow: if(active?, do: if(dir == :asc, do: "▲", else: "▼"), else: "↕")
      )

    ~H"""
    <button
      type="button"
      phx-click="sort"
      phx-value-by={@field}
      class={[
        "group flex items-center gap-1 uppercase tracking-wider transition-colors",
        @align == "right" && "justify-end",
        @active? && "text-ink",
        !@active? && "text-ink-faint hover:text-ink-muted"
      ]}
    >
      <span>{@label}</span>
      <span class={[
        "text-[8px] leading-none transition-opacity",
        @active? && "text-primary opacity-100",
        !@active? && "opacity-0 group-hover:opacity-60"
      ]}>
        {@arrow}
      </span>
    </button>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-3 py-24 text-center">
      <span class="hero-musical-note size-10 text-ink-disabled" />
      <p class="text-ink-muted">Nenhuma faixa com esses filtros.</p>
      <button phx-click="clear_filters" class="text-body-sm text-primary hover:underline">
        Limpar filtros
      </button>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp import_progress_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-caption text-ink-muted">{progress_label(@progress)}</span>
      <div class="h-[6px] w-32 rounded-full bg-white/5">
        <div
          class="h-full rounded-full bg-primary transition-[width]"
          style={"width:#{progress_pct(@progress)}%"}
        />
      </div>
    </div>
    """
  end

  attr :message, :string, required: true

  defp import_toast(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 border-b border-green/30 bg-green/10 px-5 py-2">
      <p class="text-body-sm text-ink">{@message}</p>
      <button phx-click="dismiss_import_toast" class="text-body-sm text-ink-muted hover:text-ink">
        ✕
      </button>
    </div>
    """
  end

  # Confirmation bar after a move, carrying the batch_id behind a "Desfazer".
  attr :toast, :any, required: true

  defp move_toast(assigns) do
    {:moved, n, _batch_id} = assigns.toast
    assigns = assign(assigns, :n, n)

    ~H"""
    <div class="flex items-center justify-between gap-4 border-b border-primary/30 bg-primary/10 px-5 py-2">
      <p class="text-body-sm text-ink">
        {move_toast_label(@n)}
      </p>
      <div class="flex items-center gap-3">
        <button
          :if={@n > 0}
          phx-click="undo_move"
          class="rounded-md border border-primary/40 bg-primary/15 px-2.5 py-1 text-body-sm font-semibold text-primary hover:bg-primary/25"
        >
          Desfazer
        </button>
        <button phx-click="dismiss_move_toast" class="text-body-sm text-ink-muted hover:text-ink">
          ✕
        </button>
      </div>
    </div>
    """
  end

  defp move_toast_label(0), do: "Nada foi movido."
  defp move_toast_label(1), do: "1 faixa movida."
  defp move_toast_label(n), do: "#{n} faixas movidas."

  # Bottom action bar for the discrete batch-select mode: move N / rate N / undo.
  attr :count, :integer, required: true
  attr :folders, :list, required: true
  attr :move_toast, :any, required: true

  defp batch_bar(assigns) do
    ~H"""
    <div class="border-t border-primary/30 bg-primary/10 px-5 py-2.5 backdrop-blur">
      <div class="flex flex-wrap items-center gap-x-5 gap-y-2">
        <span class="text-body-sm font-semibold text-ink">
          {@count} {if @count == 1, do: "selecionada", else: "selecionadas"}
        </span>

        <form id="batch-move" phx-change="move_selected" class="flex items-center gap-2">
          <label class="text-body-sm text-ink-muted">Mover para</label>
          <select
            name="folder"
            class="rounded-md border border-white/10 bg-input px-2 py-1 text-body-sm focus:border-primary/50 focus:outline-none"
          >
            <option value="">escolher…</option>
            <option :for={folder <- @folders} value={folder.key}>{folder.display_name}</option>
          </select>
        </form>

        <div class="flex items-center gap-2">
          <span class="text-body-sm text-ink-muted">Avaliar</span>
          <div class="flex gap-0.5">
            <button
              :for={n <- 0..10}
              phx-click="rate_selected"
              phx-value-rating={n}
              class="flex size-6 items-center justify-center rounded font-mono text-[11px] text-ink-muted transition-colors hover:bg-white/10 hover:text-ink"
            >
              {n}
            </button>
          </div>
        </div>

        <button
          :if={@move_toast}
          phx-click="undo_move"
          class="rounded-md border border-primary/40 bg-primary/15 px-2.5 py-1 text-body-sm font-semibold text-primary hover:bg-primary/25"
        >
          Desfazer
        </button>

        <button
          phx-click="clear_selection"
          class="ml-auto rounded-md border border-white/10 bg-input px-2.5 py-1 text-body-sm text-ink-muted hover:text-ink"
        >
          Limpar
        </button>
      </div>
    </div>
    """
  end

  attr :import, :map, required: true

  defp import_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-20 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/60" phx-click="hide_import"></div>
      <div class="relative max-h-[85vh] w-full max-w-3xl overflow-y-auto rounded-xl border border-white/10 bg-surface p-5">
        <div class="mb-4 flex items-center justify-between">
          <h3 class="text-[18px] font-semibold">Importar pasta ou arquivo</h3>
          <button phx-click="hide_import" class="text-ink-muted hover:text-ink">✕</button>
        </div>

        <form id="import-source" phx-submit="preview_import" class="space-y-3">
          <input
            type="text"
            name="source"
            value={@import[:source]}
            placeholder="Cole o caminho de uma pasta ou arquivo…"
            class="w-full rounded-md border border-white/8 bg-input px-3 py-2 text-body focus:border-primary/50 focus:outline-none"
          />
          <div class="flex flex-wrap items-center gap-4">
            <label class="flex items-center gap-2 text-body-sm text-ink-secondary">
              <input
                type="checkbox"
                name="ai"
                checked={Map.get(@import, :ai, true)}
                class="rounded border-white/20 bg-input"
              /> Refinar títulos com IA
            </label>
            <label class="flex items-center gap-2 text-body-sm text-ink-secondary">
              <input
                type="checkbox"
                name="soundcharts"
                checked={Map.get(@import, :soundcharts, false)}
                class="rounded border-white/20 bg-input"
              /> Resolver no Soundcharts depois (gasta cota)
            </label>
            <button class="ml-auto rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white">
              Pré-visualizar
            </button>
          </div>
        </form>

        <p
          :if={@import[:error]}
          class="mt-3 rounded-lg border border-coral/25 bg-coral/8 px-3 py-2 text-body-sm text-ink"
        >
          ⚠ {@import.error}
        </p>

        <div
          :if={@import[:loading]}
          class="mt-4 flex items-center gap-2 text-body-sm text-ink-muted"
        >
          <span class="size-2.5 animate-pulse rounded-full bg-primary"></span> Pré-visualizando…
        </div>

        <.preview_table :if={@import[:rows]} rows={@import.rows} soundcharts={@import[:soundcharts]} />
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :soundcharts, :boolean, default: false

  defp preview_table(assigns) do
    assigns =
      assigns
      |> assign(:new_rows, Enum.reject(assigns.rows, & &1.duplicate))
      |> assign(:dupes, Enum.count(assigns.rows, & &1.duplicate))

    ~H"""
    <div class="mt-5">
      <p class="mb-2 text-body-sm text-ink-muted">
        {length(@new_rows)} nova(s), {@dupes} duplicada(s)
      </p>

      <form id="import-run" phx-submit="run_import" class="space-y-1">
        <div
          :for={{row, i} <- Enum.with_index(@rows)}
          class={[
            "grid items-center gap-2 rounded-lg px-2 py-2",
            row.duplicate && "opacity-50",
            !row.duplicate && "bg-base"
          ]}
          style="grid-template-columns:1fr 1fr 1.2fr 60px 60px"
        >
          <%= if row.duplicate do %>
            <span class="truncate text-body-sm text-ink-muted">{row.artist || "—"}</span>
            <span class="truncate text-body-sm text-ink-muted">{row.title || "—"}</span>
          <% else %>
            <input type="hidden" name={"items[#{i}][source_path]"} value={row.source_path} />
            <input
              type="text"
              name={"items[#{i}][artist]"}
              value={row.artist}
              placeholder="Artista"
              class="w-full rounded-md border border-white/8 bg-input px-2 py-1 text-body-sm focus:border-primary/50 focus:outline-none"
            />
            <input
              type="text"
              name={"items[#{i}][title]"}
              value={row.title}
              placeholder="Título"
              class="w-full rounded-md border border-white/8 bg-input px-2 py-1 text-body-sm focus:border-primary/50 focus:outline-none"
            />
          <% end %>
          <span class="truncate text-caption text-ink-faint" title={row.filename}>
            {row.filename}
            <span
              :if={row.duplicate}
              class="ml-1 rounded bg-white/8 px-1.5 py-px text-[10px] text-ink-muted"
            >
              duplicada — será pulada
            </span>
            <span
              :if={row.near_dup}
              class="ml-1 rounded bg-amber/15 px-1.5 py-px text-[10px] font-semibold text-amber"
              title="Já existe uma faixa com o mesmo artista e título (versão diferente). Você ainda pode importar."
            >
              parecida já existe
            </span>
          </span>
          <span class="text-right font-mono text-caption text-ink-muted">{duration(row.duration_ms)}</span>
          <span class="text-right font-mono text-caption text-ink-faint">{format_label(row.format)}</span>
        </div>

        <div :if={@new_rows != []} class="flex justify-end pt-3">
          <button class="rounded-md bg-primary px-4 py-2 text-body-sm font-semibold text-white">
            Importar {length(@new_rows)} faixa(s){if @soundcharts, do: " + Soundcharts", else: ""}
          </button>
        </div>
        <p :if={@new_rows == []} class="pt-3 text-body-sm text-ink-faint">
          Nada novo para importar — tudo já está na biblioteca.
        </p>
      </form>
    </div>
    """
  end

  defp chip_class(active?) do
    [
      "rounded-sm border px-[9px] py-[5px] text-[11px] font-semibold transition-colors",
      active? && "border-primary/60 bg-primary/20 text-ink",
      !active? && "border-white/8 bg-input text-ink-muted hover:border-white/20"
    ]
  end

  # The row grid: an optional leading checkbox column in select mode, the cover,
  # the data columns, and a trailing ⋯ action column.
  defp grid_cols(selecting?) do
    lead = if selecting?, do: "24px ", else: ""
    "grid-template-columns:#{lead}38px 1fr 130px 52px 56px 80px 52px 64px 100px 28px"
  end

  defp row_selected?(selected, id), do: MapSet.member?(selected, id)

  # Manual override wins, then Soundcharts, then the locally-detected value — the
  # same precedence the sort/filter use (TrackQuery coalesce) and Library.effective/1.
  defp bpm(%{bpm_manual: b}) when is_number(b), do: round(b)
  defp bpm(%{soundcharts_song: %{tempo_bpm: b}}) when is_number(b), do: round(b)
  defp bpm(%{bpm_detected: b}) when is_number(b), do: round(b)
  defp bpm(_track), do: "—"

  defp camelot(%{camelot_manual: c}) when is_binary(c), do: c
  defp camelot(%{soundcharts_song: %{camelot: c}}) when is_binary(c), do: c
  defp camelot(%{camelot_detected: c}) when is_binary(c), do: c
  defp camelot(_track), do: nil

  # --- Camelot wheel (Tom filter) ---------------------------------------------

  attr :selected, :string, default: nil
  attr :compatible?, :boolean, default: false

  defp camelot_wheel(assigns) do
    neighbors = wheel_neighbors(assigns.selected, assigns.compatible?)
    assigns = assign(assigns, wedges: camelot_wedges(), neighbors: neighbors)

    ~H"""
    <svg
      viewBox="0 0 280 280"
      class="mx-auto w-full max-w-[300px]"
      role="img"
      aria-label="Roda harmônica Camelot"
    >
      <path
        :for={w <- @wedges}
        d={w.d}
        fill={w.fill}
        opacity={wedge_opacity(w.code, @selected, @neighbors)}
        stroke={wedge_stroke(w.code, @selected, @neighbors)}
        stroke-width={wedge_stroke_width(w.code, @selected, @neighbors)}
        stroke-dasharray={wedge_dash(w.code, @neighbors)}
        class="camelot-wedge cursor-pointer"
        phx-click="set_camelot"
        phx-value-code={w.code}
      />
      <text
        :for={w <- @wedges}
        x={w.lx}
        y={w.ly}
        text-anchor="middle"
        dominant-baseline="central"
        font-size="11"
        fill={if(w.code == @selected, do: "#fff", else: "rgba(255,255,255,.72)")}
        class="pointer-events-none font-mono"
      >
        {w.code}
      </text>
      <text
        x="140"
        y="136"
        text-anchor="middle"
        dominant-baseline="central"
        font-size="26"
        fill="#eef0f5"
        class="pointer-events-none font-mono"
      >
        {@selected}
      </text>
      <text
        x="140"
        y="160"
        text-anchor="middle"
        font-size="11"
        fill="#5f636f"
        class="pointer-events-none"
      >
        {wheel_caption(@selected, @compatible?)}
      </text>
    </svg>
    """
  end

  defp wheel_caption(nil, _), do: "qualquer"
  defp wheel_caption(_code, true), do: "+ compatíveis"
  defp wheel_caption(_code, false), do: "tom"

  defp wedge_opacity(code, code, _neighbors), do: "1"

  defp wedge_opacity(code, _selected, neighbors) do
    if MapSet.member?(neighbors, code), do: "0.85", else: "0.4"
  end

  defp wedge_stroke(code, code, _neighbors), do: "#eef0f5"

  defp wedge_stroke(code, _selected, neighbors) do
    if MapSet.member?(neighbors, code), do: "rgba(238,240,245,.55)", else: "none"
  end

  defp wedge_stroke_width(code, code, _neighbors), do: "2"

  defp wedge_stroke_width(code, _selected, neighbors) do
    if MapSet.member?(neighbors, code), do: "1", else: "0"
  end

  defp wedge_dash(code, neighbors), do: if(MapSet.member?(neighbors, code), do: "2 2")

  # Compatible-key set (excluding the selected one) when "incluir compatíveis" is on.
  defp wheel_neighbors(nil, _), do: MapSet.new()
  defp wheel_neighbors(_code, false), do: MapSet.new()

  defp wheel_neighbors(code, true) do
    code |> Camelot.neighbors() |> MapSet.new() |> MapSet.delete(code)
  end

  # The 24 wedges with precomputed SVG paths + label positions + muted-rainbow fills.
  defp camelot_wedges do
    for {letter, ri, ro, lr} <- [{"A", 56, 90, 73}, {"B", 94, 132, 113}], n <- 1..12 do
      deg = rem(n, 12) * 30
      {lx, ly} = wheel_point(lr, deg)

      %{
        code: "#{n}#{letter}",
        d: sector_path(ri, ro, deg - 13.5, deg + 13.5),
        lx: lx,
        ly: ly,
        fill: "hsl(#{rem((n - 1) * 30, 360)} #{wheel_sat(letter)}% #{wheel_light(letter)}%)"
      }
    end
  end

  defp wheel_sat("A"), do: 38
  defp wheel_sat("B"), do: 42
  defp wheel_light("A"), do: 44
  defp wheel_light("B"), do: 52

  # Dot color in the trigger button for the current code (just its number's hue).
  defp camelot_dot(code) do
    n = code |> String.trim_trailing("A") |> String.trim_trailing("B") |> String.to_integer()
    "hsl(#{rem((n - 1) * 30, 360)} 45% 52%)"
  end

  # Annular sector between radii `ri`/`ro` from `a1`° to `a2`° (0° = top, clockwise).
  defp sector_path(ri, ro, a1, a2) do
    {x1, y1} = wheel_point(ro, a1)
    {x2, y2} = wheel_point(ro, a2)
    {x3, y3} = wheel_point(ri, a2)
    {x4, y4} = wheel_point(ri, a1)
    "M#{x1} #{y1} A#{ro} #{ro} 0 0 1 #{x2} #{y2} L#{x3} #{y3} A#{ri} #{ri} 0 0 0 #{x4} #{y4} Z"
  end

  defp wheel_point(r, deg) do
    rad = deg * :math.pi() / 180

    {Float.round(@wheel_cx + r * :math.sin(rad), 2),
     Float.round(@wheel_cy - r * :math.cos(rad), 2)}
  end

  defp energy_pct(%{soundcharts_song: %{energy: e}}) when is_number(e), do: round(e * 100)
  defp energy_pct(_track), do: 0

  defp progress_label(%{status: :queued}), do: "Importando — na fila…"
  defp progress_label(%{done: d, total: t}), do: "Importando #{d}/#{t}…"

  defp progress_pct(%{done: d, total: t}) when is_integer(t) and t > 0, do: round(d / t * 100)
  defp progress_pct(_progress), do: 0

  defp duration(ms) when is_integer(ms) and ms > 0 do
    secs = div(ms, 1000)
    "#{div(secs, 60)}:#{String.pad_leading(to_string(rem(secs, 60)), 2, "0")}"
  end

  defp duration(_ms), do: "—"

  defp format_label(format) when is_atom(format) and not is_nil(format),
    do: format |> to_string() |> String.upcase()

  defp format_label(_format), do: "—"
end
