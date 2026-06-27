defmodule BeatgridWeb.LibraryLive do
  @moduledoc "Biblioteca — the filterable track table."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library
  alias Beatgrid.Library.{GenreFolders, TrackQuery, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Workers.ImportWorker

  # "Parecidas" widens the energy window by ±this many points (0–100) around the
  # reference track's effective energy.
  @energy_window 12

  @confidences [{"alta", :high}, {"média", :medium}, {"baixa", :low}]

  # The 24 Camelot wheel codes, 1A..12B, for the Tom filter <select>.
  @camelot_codes for n <- 1..12, letter <- ["A", "B"], do: "#{n}#{letter}"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe_import()

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
       move_toast: nil,
       import: nil,
       import_progress: nil,
       import_toast: nil
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
      |> put_filter(:camelot, params["camelot"])
      |> put_toggle(:camelot_compatible, params["camelot_compatible"])

    {:noreply, socket |> assign(filters: filters) |> load_tracks()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(filters: %{}) |> load_tracks()}
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

  def handle_event("select_all", _params, socket) do
    selected = MapSet.new(socket.assigns.tracks, & &1.id)
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

      Oban.insert(
        ImportWorker.new(%{
          "items" => items,
          "batch_id" => batch_id,
          "resolve_soundcharts" => import_state.soundcharts
        })
      )

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

  defp load_tracks(socket) do
    filters = Map.put(socket.assigns.filters, :sort, socket.assigns.sort)
    assign(socket, tracks: TrackQuery.library(filters))
  end

  defp update_filter(socket, key, nil),
    do: assign(socket, filters: Map.delete(socket.assigns.filters, key))

  defp update_filter(socket, key, val),
    do: assign(socket, filters: Map.put(socket.assigns.filters, key, val))

  defp toggle(current, val), do: if(current == val, do: nil, else: val)
  defp put_filter(filters, key, val) when val in [nil, ""], do: Map.delete(filters, key)
  defp put_filter(filters, key, val), do: Map.put(filters, key, val)

  # A checkbox sends "on" when ticked and is absent when unticked.
  defp put_toggle(filters, key, "on"), do: Map.put(filters, key, true)
  defp put_toggle(filters, key, _absent), do: Map.delete(filters, key)

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
            <span class="font-mono text-body-sm text-ink-muted">{length(@tracks)} faixas</span>
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

        <div class="flex min-h-0 flex-1">
          <aside class="w-60 shrink-0 overflow-y-auto border-r border-white/6 bg-rail px-4 py-4">
            <.filters_panel filters={@filters} folders={@folders} />
          </aside>

          <section class="min-w-0 flex-1 overflow-y-auto px-5 py-4">
            <.track_table
              :if={@tracks != []}
              tracks={@tracks}
              sort={@sort}
              selecting?={@selecting?}
              selected={@selected}
              row_menu={@row_menu}
              folders={@folders}
            />
            <.empty_state :if={@tracks == []} />
          </section>
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

  defp filters_panel(assigns) do
    assigns = assign(assigns, confidences: @confidences, camelot_codes: @camelot_codes)

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

    <form id="library-filters" phx-change="filter" class="mt-4 space-y-3.5">
      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Tom</p>
        <select
          name="camelot"
          class="w-full rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
        >
          <option value="" selected={!@filters[:camelot]}>Qualquer</option>
          <option :for={code <- @camelot_codes} value={code} selected={@filters[:camelot] == code}>
            {code}
          </option>
        </select>
        <label class="mt-1.5 flex items-center gap-1.5 text-[11px] text-ink-muted">
          <input
            type="checkbox"
            name="camelot_compatible"
            checked={@filters[:camelot_compatible] == true}
            class="rounded border-white/20 bg-input"
          /> incluir compatíveis
        </label>
      </div>

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
        <.sort_header field={:confidence} label="Sinal" sort={@sort} align="right" />
        <span></span>
      </div>
      <div
        :for={track <- @tracks}
        class={[
          "grid items-center gap-2 rounded-lg px-1.5 py-1.5",
          row_selected?(@selected, track.id) && "bg-primary/10",
          !row_selected?(@selected, track.id) && "hover:bg-surface-2"
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
        />
        <.link navigate={~p"/track/#{track.id}"} class="contents">
          <div class="min-w-0">
            <p class="truncate text-body font-medium">{track.tag_title || track.filename}</p>
            <p class="truncate text-caption text-ink-muted">{track.tag_artist || "—"}</p>
          </div>
          <div><.folder_badge :if={track.genre_folder} folder={track.genre_folder} /></div>
          <span class="text-right font-mono text-body text-primary">{bpm(track)}</span>
          <.camelot_seal value={camelot(track)} />
          <div class="h-[5px] w-full rounded-full bg-white/5">
            <div class="h-full rounded-full bg-green" style={"width:#{energy_pct(track)}%"} />
          </div>
          <div class="text-right"><.rating_badge value={track.rating} /></div>
          <div class="text-right"><.confidence_chip level={track.sc_match_confidence} /></div>
        </.link>
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
    "grid-template-columns:#{lead}38px 1fr 130px 52px 56px 80px 52px 100px 28px"
  end

  defp row_selected?(selected, id), do: MapSet.member?(selected, id)

  # Soundcharts value, falling back to the locally-detected one.
  defp bpm(%{soundcharts_song: %{tempo_bpm: b}}) when is_number(b), do: round(b)
  defp bpm(%{bpm_detected: b}) when is_number(b), do: round(b)
  defp bpm(_track), do: "—"

  defp camelot(%{soundcharts_song: %{camelot: c}}) when is_binary(c), do: c
  defp camelot(%{camelot_detected: c}) when is_binary(c), do: c
  defp camelot(_track), do: nil

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
