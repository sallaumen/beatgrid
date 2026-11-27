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
  alias Beatgrid.Workers.{MoveBatchWorker, UndoBatchWorker}
  alias BeatgridWeb.LibraryNavigation

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
  def mount(%{"importar" => "1"}, _session, socket),
    do: {:ok, redirect(socket, to: ~p"/importados?origem=local")}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Library.subscribe_import()
      Operations.subscribe()
      Playback.subscribe()
    end

    np = Playback.now_playing()

    {:ok,
     socket
     |> assign(
       page_title: "Biblioteca",
       folders: GenreFolders.list(),
       filters: %{},
       library_path: "/",
       filters_open?: false,
       sort: {:artist, :asc},
       selecting?: false,
       selected: MapSet.new(),
       row_menu: nil,
       folder_menu: nil,
       tom_wheel_open: false,
       move_toast: nil,
       playing_track_id: np.track_id,
       all_tags: Tracks.all_tags()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = LibraryNavigation.filters(params)
    sort = LibraryNavigation.sort(params)

    {:noreply,
     socket
     |> assign(filters: filters, sort: sort, library_path: LibraryNavigation.path(filters, sort))
     |> load_tracks()}
  end

  @impl true
  def handle_event("toggle_genre", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> update_filter(:genre_folder, toggle(socket.assigns.filters[:genre_folder], key))
     |> patch_library()}
  end

  def handle_event("toggle_confidence", %{"level" => level}, socket) do
    {:noreply,
     socket
     |> update_filter(:confidence, toggle(socket.assigns.filters[:confidence], level))
     |> patch_library()}
  end

  def handle_event("toggle_unclassified", _params, socket) do
    {:noreply,
     socket
     |> update_filter(:unclassified, toggle(socket.assigns.filters[:unclassified], true))
     |> patch_library()}
  end

  def handle_event("toggle_tag", %{"tag" => tag}, socket) do
    {:noreply,
     socket
     |> update_filter(:tag, toggle(socket.assigns.filters[:tag], tag))
     |> patch_library()}
  end

  # Clicking a column header sorts by that field — toggling asc/desc when it's
  # already the active field, otherwise starting ascending. `by` is
  # client-supplied, so it's whitelisted before touching atoms.
  def handle_event("sort", %{"by" => by}, socket) do
    case LibraryNavigation.sort_field(by) do
      nil ->
        {:noreply, socket}

      field ->
        {cur_field, cur_dir} = socket.assigns.sort
        dir = if cur_field == field, do: flip_dir(cur_dir), else: :asc
        {:noreply, socket |> assign(sort: {field, dir}) |> patch_library()}
    end
  end

  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    filters =
      for key <- ~w(search rating_min rating_max bpm_min bpm_max energy_min energy_max)a,
          {:ok, value} <- [Map.fetch(params, Atom.to_string(key))],
          reduce: socket.assigns.filters do
        current -> put_filter(current, key, value)
      end

    {:noreply, socket |> assign(filters: filters) |> patch_library()}
  end

  def handle_event("remove_filter", %{"filter" => group}, socket) do
    case Enum.find(active_filter_items(socket.assigns.filters, socket.assigns.folders), fn
           {key, _, _} -> key == group
         end) do
      {_, keys, _} ->
        {:noreply, socket |> update(:filters, &Map.drop(&1, keys)) |> patch_library()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_library_filters", _params, socket) do
    {:noreply,
     assign(socket, filters_open?: not socket.assigns.filters_open?, tom_wheel_open: false)}
  end

  def handle_event("toggle_tom_wheel", _params, socket),
    do: {:noreply, assign(socket, tom_wheel_open: not socket.assigns.tom_wheel_open)}

  def handle_event("close_tom_wheel", _params, socket),
    do: {:noreply, assign(socket, tom_wheel_open: false)}

  # A wedge toggles. The native picker reports an absolute selection, including
  # a repeated value after a LiveView form recovery.
  def handle_event("set_camelot", %{"code" => code}, socket) do
    change_key_filter(socket, toggle(socket.assigns.filters[:camelot], code))
  end

  def handle_event("choose_camelot", %{"code" => code}, socket),
    do: change_key_filter(socket, code)

  def handle_event("toggle_camelot_compatible", _params, socket) do
    value = if socket.assigns.filters[:camelot_compatible] == true, do: nil, else: true
    {:noreply, socket |> update_filter(:camelot_compatible, value) |> patch_library()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(filters: %{}) |> patch_library()}
  end

  def handle_event("toggle_gold_filter", _params, socket) do
    current = socket.assigns.filters[:gold]

    {:noreply,
     socket |> update_filter(:gold, if(current, do: nil, else: true)) |> patch_library()}
  end

  # --- per-row ⋯ menu ---

  def handle_event("row_menu_toggle", %{"id" => id}, socket) do
    {:noreply, assign(socket, row_menu: toggle(socket.assigns.row_menu, id), folder_menu: nil)}
  end

  def handle_event("close_row_menu", _params, socket),
    do: {:noreply, assign(socket, row_menu: nil)}

  # The inline folder picker on the "Pasta" column — opening it closes the ⋯ menu
  # so only one popover is ever open. It reuses `move_track` to do the move.
  def handle_event("folder_menu_toggle", %{"id" => id}, socket) do
    {:noreply, assign(socket, folder_menu: toggle(socket.assigns.folder_menu, id), row_menu: nil)}
  end

  def handle_event("close_folder_menu", _params, socket),
    do: {:noreply, assign(socket, folder_menu: nil)}

  def handle_event("move_track", %{"track_id" => id, "to" => folder_key}, socket) do
    socket = assign(socket, row_menu: nil, folder_menu: nil)

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
      track -> {:noreply, socket |> assign(filters: similar_filters(track)) |> patch_library()}
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
    if socket.assigns.selecting? and Enum.any?(socket.assigns.tracks, &(&1.id == id)) do
      selected =
        if MapSet.member?(socket.assigns.selected, id) do
          MapSet.delete(socket.assigns.selected, id)
        else
          MapSet.put(socket.assigns.selected, id)
        end

      {:noreply, assign(socket, selected: selected)}
    else
      {:noreply, socket}
    end
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

  # A big selection means many disk renames — the move runs in a background
  # worker (durable, visible in /jobs) and {:tracks_moved, _} pops the toast.
  def handle_event("move_selected", %{"folder" => folder_key}, socket)
      when folder_key not in [nil, ""] do
    ids = MapSet.to_list(socket.assigns.selected)
    {:ok, _job} = MoveBatchWorker.enqueue(ids, folder_key)

    {:noreply, assign(socket, move_toast: {:moving, length(ids)}, selected: MapSet.new())}
  end

  def handle_event("move_selected", _params, socket), do: {:noreply, socket}

  def handle_event("rate_selected", %{"rating" => rating}, socket) do
    case Integer.parse(rating) do
      {n, ""} when n in 0..10 ->
        {:ok, _count} = Tracks.rate_many(MapSet.to_list(socket.assigns.selected), n)
        {:noreply, load_tracks(socket)}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("undo_move", _params, socket) do
    case socket.assigns.move_toast do
      {:moved, _n, batch_id} ->
        {:ok, _job} = UndoBatchWorker.enqueue(batch_id)
        {:noreply, assign(socket, move_toast: :undoing)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_move_toast", _params, socket),
    do: {:noreply, assign(socket, move_toast: nil)}

  @impl true
  def handle_info({:import_progress, %{status: :done}}, socket),
    do: {:noreply, load_tracks(socket)}

  def handle_info({:import_progress, _progress}, socket), do: {:noreply, socket}

  # The background batch move finished — swap the "movendo…" toast for the
  # Desfazer one and refresh the rows.
  def handle_info({:tracks_moved, %{moved: moved, batch_id: batch_id}}, socket) do
    {:noreply,
     socket
     |> assign(move_toast: {:moved, moved, batch_id})
     |> load_tracks()}
  end

  # The background undo finished — the rows return to their folders.
  def handle_info({:batch_undone, _result}, socket) do
    {:noreply, socket |> assign(move_toast: nil) |> load_tracks()}
  end

  def handle_info({:now_playing, np}, socket) do
    {:noreply, assign(socket, playing_track_id: np.track_id)}
  end

  # Resets to the first page — used after any filter/sort/move change. Loads page 1
  # (100 rows) + the total count so the header and has-more? are accurate.
  defp load_tracks(socket) do
    filters = base_filters(socket)
    total = TrackQuery.count_library(filters)
    tracks = TrackQuery.library(Map.merge(filters, %{limit: @per_page, offset: 0}))

    socket
    |> retain_matching_selection(filters)
    |> assign(
      tracks: tracks,
      total: total,
      page: 1,
      has_more?: length(tracks) < total
    )
  end

  # The batch controls label the current result scope. Keep matching selected
  # ids from every page, not just the rows currently loaded on screen.
  defp retain_matching_selection(socket, filters) do
    selected = socket.assigns.selected

    if MapSet.size(selected) == 0 do
      socket
    else
      retained =
        filters
        |> Map.put(:ids, MapSet.to_list(selected))
        |> TrackQuery.library_ids()
        |> MapSet.new()

      dropped = MapSet.size(selected) - MapSet.size(retained)
      socket |> assign(selected: retained) |> selection_notice(dropped)
    end
  end

  defp selection_notice(socket, 0), do: socket

  defp selection_notice(socket, 1),
    do: put_flash(socket, :info, "1 faixa saiu da seleção por não estar mais nos resultados.")

  defp selection_notice(socket, n),
    do:
      put_flash(
        socket,
        :info,
        "#{n} faixas saíram da seleção por não estarem mais nos resultados."
      )

  defp total_label(1), do: "1 faixa"
  defp total_label(n), do: "#{n} faixas"

  # Replacing the list location keeps the current result shareable and restores
  # it after opening a track without putting every keystroke in browser history.
  defp patch_library(socket) do
    filters = LibraryNavigation.filters(socket.assigns.filters)
    to = LibraryNavigation.path(filters, socket.assigns.sort)
    socket = assign(socket, filters: filters, row_menu: nil, folder_menu: nil)

    if to == socket.assigns.library_path,
      do: socket,
      else: push_patch(socket, to: to, replace: true)
  end

  defp base_filters(socket), do: Map.put(socket.assigns.filters, :sort, socket.assigns.sort)

  defp change_key_filter(socket, code),
    do: {:noreply, socket |> update_filter(:camelot, code) |> patch_library()}

  defp update_filter(socket, key, val),
    do: assign(socket, filters: put_filter(socket.assigns.filters, key, val))

  defp toggle(current, val), do: if(current == val, do: nil, else: val)
  defp put_filter(filters, key, val) when val in [nil, ""], do: Map.delete(filters, key)
  defp put_filter(filters, key, val), do: Map.put(filters, key, val)

  # Search is already visible in its input. Ranges and the harmonic match are
  # presented as one criterion each so removing them clears their entire group.
  defp active_filter_items(filters, folders) do
    folder = filters[:genre_folder]
    folder_name = Enum.find_value(folders, folder, &(&1.key == folder && &1.display_name))

    confidence =
      Enum.find_value(@confidences, fn {label, level} ->
        filters[:confidence] == to_string(level) && label
      end)

    for {group, keys, label} <- [
          {"genre_folder", [:genre_folder], folder_name && "Pasta: #{folder_name}"},
          {"unclassified", [:unclassified], filters[:unclassified] && "Não classificadas"},
          {"gold", [:gold], filters[:gold] && "Ouro"},
          {"tag", [:tag], filters[:tag] && "Tag: #{filters[:tag]}"},
          {"confidence", [:confidence], confidence && "Confiança #{confidence}"},
          {"camelot", [:camelot, :camelot_compatible], camelot_filter_label(filters)},
          {"rating", [:rating_min, :rating_max],
           range_label("Nota", filters[:rating_min], filters[:rating_max])},
          {"energy", [:energy_min, :energy_max],
           range_label("Energia", filters[:energy_min], filters[:energy_max])},
          {"bpm", [:bpm_min, :bpm_max], range_label("BPM", filters[:bpm_min], filters[:bpm_max])}
        ],
        is_binary(label),
        do: {group, keys, label}
  end

  defp camelot_filter_label(%{camelot: key, camelot_compatible: true}),
    do: "Tom #{key} + compatíveis"

  defp camelot_filter_label(%{camelot: key}), do: "Tom #{key}"
  defp camelot_filter_label(_filters), do: nil

  defp range_label(_label, nil, nil), do: nil
  defp range_label(label, min, nil), do: "#{label} ≥ #{min}"
  defp range_label(label, nil, max), do: "#{label} ≤ #{max}"
  defp range_label(label, min, max), do: "#{label} #{min}–#{max}"

  defp remove_filter_action(items, group) do
    target =
      case Enum.find(items, fn {key, _, _} -> key != group end) do
        {key, _, _} ->
          "#library-remove-#{key}"

        # Compact screens must not summon the software keyboard on the final removal.
        nil ->
          "#library-filter-toggle, #library-filter-panel button[phx-click=toggle_gold_filter]"
      end

    JS.push("remove_filter", value: %{filter: group}) |> JS.focus(to: target)
  end

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
    assigns =
      assign(assigns, :active_filters, active_filter_items(assigns.filters, assigns.folders))

    ~H"""
    <.app_shell flash={@flash} active={:biblioteca} socket={@socket}>
      <%!-- Below md the 44px menu button, 8px vertical padding and 1px
      hairline take room above this viewport; the player reserve comes from the shell. --%>
      <div class="flex h-[calc(100dvh_-_var(--workspace-player-reserve,5rem)_-_3.25rem_-_1px)] w-full max-w-[1840px] flex-col md:h-[calc(100dvh_-_var(--workspace-player-reserve,5rem))]">
        <header class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 gap-y-3 border-b border-white/6 bg-rail px-3 py-3 lg:flex lg:flex-wrap lg:px-5">
          <div class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
            <h1 class="text-[22px] font-semibold">Biblioteca</h1>
            <span role="status" class="font-mono text-body-sm text-ink-muted tabular-nums">
              {total_label(@total)}
            </span>
          </div>
          <.link
            navigate={~p"/importados?origem=local"}
            class="justify-self-end rounded-md border border-white/10 bg-input px-3 py-2 text-body-sm font-semibold text-ink-secondary hover:text-ink"
          >
            Importar
          </.link>

          <form
            id="library-search"
            phx-change="filter"
            phx-submit="filter"
            class="relative col-span-2 min-w-0 lg:ml-auto lg:min-w-56 lg:max-w-3xl lg:flex-1"
          >
            <span
              class="hero-magnifying-glass pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-muted"
              aria-hidden="true"
            />
            <input
              type="search"
              id="library-search-input"
              name="search"
              phx-debounce="250"
              value={@filters[:search] || ""}
              aria-label="Buscar artista, título ou ID da faixa"
              placeholder="Buscar artista ou título…"
              class="w-full rounded-md border border-white/10 bg-input py-2 pl-9 pr-3 text-body placeholder:text-ink-faint"
            />
          </form>

          <div class="col-span-2 flex min-w-0 flex-wrap items-center gap-2 lg:justify-end">
            <%= if @selecting? do %>
              <div class="flex min-w-0 flex-wrap items-center gap-2">
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
                  Limpar seleção
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
            <button
              id="library-filter-toggle"
              type="button"
              phx-click="toggle_library_filters"
              aria-controls="library-filter-panel"
              aria-expanded={to_string(@filters_open?)}
              class={[
                "inline-flex items-center gap-1 rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm font-semibold xl:hidden",
                if(@filters_open?, do: "text-primary", else: "text-ink-muted")
              ]}
            >
              <span class="hero-adjustments-horizontal size-4" aria-hidden="true" /> Filtros
            </button>
          </div>
          <div
            :if={@active_filters != []}
            id="library-active-filters"
            role="group"
            aria-label="Filtros ativos"
            class="col-span-2 flex min-w-0 flex-wrap items-center gap-1.5 lg:basis-full"
          >
            <button
              :for={{group, _, label} <- @active_filters}
              id={"library-remove-#{group}"}
              type="button"
              phx-click={remove_filter_action(@active_filters, group)}
              aria-label={"Remover filtro #{label}"}
              class="inline-flex min-h-9 min-w-0 max-w-full items-center gap-2 rounded-sm border border-primary/35 bg-primary/10 px-2 py-1 text-body-sm font-semibold text-ink hover:border-primary/60 hover:bg-primary/20 sm:min-h-7"
            >
              <span class="min-w-0 break-words text-left">{label}</span>
              <span class="hero-x-mark size-4 shrink-0 text-ink-muted" aria-hidden="true" />
            </button>
          </div>
        </header>

        <.move_toast :if={@move_toast} toast={@move_toast} />

        <div class="relative flex min-h-0 flex-1 flex-col xl:flex-row">
          <aside
            id="library-filter-panel"
            aria-label="Filtros da biblioteca"
            class={[
              "max-h-[45dvh] shrink-0 overflow-y-auto border-b border-white/6 bg-rail px-4 py-3 xl:block xl:max-h-none xl:w-60 xl:border-r xl:border-b-0 xl:py-4",
              !@filters_open? && "hidden"
            ]}
          >
            <.filters_panel
              filters={@filters}
              folders={@folders}
              tags={@all_tags}
              sort={@sort}
              wheel_open?={@tom_wheel_open}
            />
          </aside>

          <section
            id="library-rows"
            class="min-h-0 min-w-0 flex-1 overflow-y-auto px-2 py-3 sm:px-5 sm:py-4"
          >
            <.track_table
              :if={@tracks != []}
              tracks={@tracks}
              sort={@sort}
              selecting?={@selecting?}
              selected={@selected}
              row_menu={@row_menu}
              folder_menu={@folder_menu}
              folders={@folders}
              playing_id={@playing_track_id}
              library_path={@library_path}
              show_paths?={is_binary(@filters[:search])}
            />
            <button
              :if={@has_more?}
              type="button"
              id="library-sentinel"
              phx-hook=".InfiniteScroll"
              phx-click="load_more"
              class="w-full py-4 text-center text-body-sm text-ink-muted hover:text-ink"
            >
              Carregar mais faixas
            </button>
            <.empty_state :if={@tracks == []} filtered?={@filters != %{}} />
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

          <div
            :if={@tom_wheel_open}
            class="fixed inset-0 z-20 bg-black/40 xl:bg-transparent"
            phx-click="close_tom_wheel"
            aria-hidden="true"
          />
          <.focus_wrap
            :if={@tom_wheel_open}
            id="library-wheel"
            role="dialog"
            aria-modal="true"
            aria-labelledby="library-wheel-title"
            phx-window-keydown="close_tom_wheel"
            phx-key="Escape"
            phx-mounted={JS.focus(to: "#library-wheel-code")}
            phx-remove={JS.focus(to: "#library-wheel-toggle")}
            class="fixed inset-x-3 top-1/2 z-30 mx-auto max-h-[calc(100dvh_-_2rem)] max-w-[324px] -translate-y-1/2 overflow-y-auto rounded-lg border border-white/10 bg-surface p-4 shadow-lg xl:absolute xl:inset-x-auto xl:left-[15.5rem] xl:top-3 xl:max-h-[calc(100%_-_1.5rem)] xl:w-[324px] xl:translate-y-0"
          >
            <div class="mb-2 flex items-center justify-between">
              <h2 id="library-wheel-title" class="text-body-lg font-semibold text-ink">
                Roda harmônica
              </h2>
              <button
                phx-click="close_tom_wheel"
                type="button"
                class="grid size-8 place-items-center rounded-md text-ink-muted hover:text-ink"
                aria-label="Fechar roda harmônica"
              >
                <span class="hero-x-mark size-4" />
              </button>
            </div>
            <.camelot_wheel
              selected={@filters[:camelot]}
              compatible?={@filters[:camelot_compatible] == true}
            />
            <label class="mt-2 flex cursor-pointer items-center gap-2 text-body text-ink-muted">
              <input
                type="checkbox"
                checked={@filters[:camelot_compatible] == true}
                phx-click="toggle_camelot_compatible"
                class="rounded border-white/20 bg-input"
              /> incluir compatíveis
            </label>
          </.focus_wrap>
        </div>

        <.batch_bar
          :if={@selecting? and MapSet.size(@selected) > 0}
          count={MapSet.size(@selected)}
          folders={@folders}
          move_toast={@move_toast}
        />
      </div>
    </.app_shell>
    """
  end

  attr :filters, :map, required: true
  attr :folders, :list, required: true
  attr :tags, :list, default: []

  attr :sort, :any, required: true
  attr :wheel_open?, :boolean, required: true

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

    <form
      id="library-compact-sort"
      phx-change="sort"
      class="mt-3 flex flex-wrap items-center gap-2 lg:hidden"
    >
      <label for="library-sort-field" class="text-body-sm text-ink-muted">Ordenar por</label>
      <select
        id="library-sort-field"
        name="by"
        class="h-8 rounded-md border border-white/8 bg-input px-2 py-1 text-body-sm"
      >
        <option
          :for={
            {field, label} <- [
              artist: "Artista",
              folder: "Pasta",
              bpm: "BPM",
              key: "Tom",
              energy: "Energia",
              rating: "Nota",
              loudness: "Volume",
              confidence: "Sinal"
            ]
          }
          value={field}
          selected={field == elem(@sort, 0)}
        >
          {label}
        </option>
      </select>
      <button
        type="button"
        phx-click="sort"
        phx-value-by={elem(@sort, 0)}
        aria-label="Inverter ordem"
        class="rounded-md px-2 py-1 text-body-sm text-ink-muted hover:text-ink"
      >
        {if elem(@sort, 1) == :asc, do: "Crescente", else: "Decrescente"}
      </button>
    </form>

    <div class="mt-3 mb-3">
      <button
        phx-click="toggle_gold_filter"
        aria-pressed={to_string(@filters[:gold] == true)}
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
        aria-pressed={to_string(@filters[:unclassified] == true)}
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
        aria-pressed={to_string(@filters[:genre_folder] == folder.key)}
        class={chip_class(@filters[:genre_folder] == folder.key)}
        style={
          @filters[:genre_folder] == folder.key &&
            "--c:#{folder_color(folder.key)};color:var(--color-ink);background:color-mix(in srgb,#{folder_color(folder.key)} 22%,transparent);border-color:color-mix(in srgb,#{folder_color(folder.key)} 60%,transparent)"
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
          aria-pressed={to_string(@filters[:tag] == tag)}
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
        aria-pressed={to_string(@filters[:confidence] == to_string(level))}
        class={chip_class(@filters[:confidence] == to_string(level))}
      >
        {label}
      </button>
    </div>

    <div class="mt-4">
      <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Tom</p>
      <button
        id="library-wheel-toggle"
        type="button"
        phx-click="toggle_tom_wheel"
        aria-label={"Escolher tom, #{@filters[:camelot] || "qualquer"}"}
        aria-haspopup="dialog"
        aria-expanded={to_string(@wheel_open?)}
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

    <form id="library-filters" phx-change="filter" phx-submit="filter" class="mt-4 max-w-52 space-y-4">
      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Nota</p>
        <div class="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-1.5">
          <input
            type="number"
            name="rating_min"
            min="0"
            max="10"
            aria-label="Nota mínima"
            placeholder="min"
            value={@filters[:rating_min]}
            class="w-full min-w-0 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50"
          />
          <span class="text-ink-faint">–</span>
          <input
            type="number"
            name="rating_max"
            min="0"
            max="10"
            aria-label="Nota máxima"
            placeholder="max"
            value={@filters[:rating_max]}
            class="w-full min-w-0 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50"
          />
        </div>
      </div>

      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
          Energia
        </p>
        <div class="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-1.5">
          <input
            type="number"
            name="energy_min"
            min="0"
            max="100"
            aria-label="Energia mínima"
            placeholder="min"
            value={@filters[:energy_min]}
            class="w-full min-w-0 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50"
          />
          <span class="text-ink-faint">–</span>
          <input
            type="number"
            name="energy_max"
            min="0"
            max="100"
            aria-label="Energia máxima"
            placeholder="max"
            value={@filters[:energy_max]}
            class="w-full min-w-0 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50"
          />
        </div>
      </div>

      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
          Faixa de BPM
        </p>
        <div class="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-1.5">
          <input
            type="number"
            name="bpm_min"
            aria-label="BPM mínimo"
            placeholder="min"
            value={@filters[:bpm_min]}
            class="w-full min-w-0 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50"
          />
          <span class="text-ink-faint">–</span>
          <input
            type="number"
            name="bpm_max"
            aria-label="BPM máximo"
            placeholder="max"
            value={@filters[:bpm_max]}
            class="w-full min-w-0 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50"
          />
        </div>
      </div>
    </form>
    """
  end

  attr :tracks, :list, required: true
  attr :library_path, :string, required: true
  attr :show_paths?, :boolean, default: false
  attr :sort, :any, required: true
  attr :selecting?, :boolean, required: true
  attr :selected, :any, required: true
  attr :row_menu, :string, required: true
  attr :folder_menu, :string, required: true
  attr :folders, :list, required: true
  attr :playing_id, :string, default: nil

  defp track_table(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class={[
        "lib-grid grid items-center gap-2 px-1.5 pb-2 text-[10px] font-semibold uppercase tracking-wider text-ink-faint",
        @selecting? && "is-selecting"
      ]}>
        <span :if={@selecting?}></span>
        <span></span>
        <.sort_header field={:artist} label="Faixa" sort={@sort} />
        <div class="hidden lg:block">
          <.sort_header field={:folder} label="Pasta" sort={@sort} />
        </div>
        <.sort_header field={:bpm} label="BPM" sort={@sort} align="right" />
        <.sort_header field={:key} label="Tom" sort={@sort} />
        <span class="hidden wide:block">
          <.sort_header field={:energy} label="Energia" sort={@sort} />
        </span>
        <div class="hidden lg:block">
          <.sort_header field={:rating} label="Nota" sort={@sort} align="right" />
        </div>
        <span class="hidden wide:block">
          <.sort_header field={:loudness} label="Vol." sort={@sort} align="right" />
        </span>
        <div class="hidden lg:block">
          <.sort_header field={:confidence} label="Sinal" sort={@sort} align="right" />
        </div>
        <span></span>
      </div>
      <div
        :for={track <- @tracks}
        id={"library-track-#{track.id}"}
        class={[
          "lib-grid grid items-center gap-2 rounded-lg px-1.5 py-1.5",
          @selecting? && "is-selecting",
          cond do
            track.id == @playing_id -> "bg-primary/15 ring-1 ring-primary/40"
            row_selected?(@selected, track.id) -> "bg-primary/10"
            true -> "hover:bg-surface-2"
          end
        ]}
      >
        <button
          :if={@selecting?}
          type="button"
          phx-click="toggle_select"
          phx-value-id={track.id}
          aria-pressed={to_string(row_selected?(@selected, track.id))}
          class="flex items-center justify-center"
          aria-label={"Selecionar #{track.tag_title || track.filename}"}
          title="Selecionar"
        >
          <span class={[
            "flex size-[18px] items-center justify-center rounded-[5px] border text-[11px] leading-none transition-colors",
            row_selected?(@selected, track.id) && "border-primary bg-primary-deep text-white",
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
              navigate={track_path(track.id, @library_path)}
              class="line-clamp-2 min-w-0 break-words text-body font-medium leading-tight text-ink hover:text-primary hover:underline lg:truncate"
              title={track.tag_title || track.filename}
            >
              {track.tag_title || track.filename}
            </.link>
            <.ouro_badge track={track} />
            <span
              :if={track.source_playlist == "recorte"}
              title="Recorte — gravada por você a partir de um set importado"
              class="shrink-0 rounded-full bg-primary/15 px-1.5 py-px text-[10px] font-semibold text-primary/90"
            >
              ✂
            </span>
          </div>
          <p class="mt-0.5 truncate text-caption text-ink-muted" title={track.tag_artist}>
            {track.tag_artist || "—"}
          </p>
        </div>
        <.folder_cell track={track} open?={@folder_menu == track.id} folders={@folders} />
        <span class="text-right font-mono text-body text-primary">{bpm(track)}</span>
        <.camelot_seal value={camelot(track)} />
        <div class="hidden h-[5px] w-full rounded-full bg-white/5 wide:block">
          <div class="h-full rounded-full bg-green" style={"width:#{energy_pct(track)}%"} />
        </div>
        <div class="hidden text-right lg:block"><.rating_badge value={track.rating} /></div>
        <div class="hidden text-right wide:block">
          <span
            :if={track.loudness_lufs}
            class="text-ink-secondary font-mono text-caption"
            title={format_lufs(track.loudness_lufs)}
          >
            {format_gain(Loudness.gain_db(track.loudness_lufs, track.true_peak_dbtp))}
          </span>
          <span :if={!track.loudness_lufs} class="text-ink-faint text-caption">–</span>
        </div>
        <div class="hidden text-right lg:block">
          <.confidence_chip level={track.sc_match_confidence} />
        </div>
        <.row_menu
          track={track}
          open?={@row_menu == track.id}
          folders={@folders}
          library_path={@library_path}
        />
        <p
          :if={@show_paths?}
          class={[
            "col-end-[-1] min-w-0 break-words font-mono text-body-sm leading-relaxed text-ink-secondary [overflow-wrap:anywhere]",
            if(@selecting?, do: "col-start-3", else: "col-start-2")
          ]}
        >
          {track.rel_path}
        </p>
      </div>
    </div>
    """
  end

  # The "Pasta" column: the current folder (or a subtle placeholder when unfiled)
  # as a button that opens a compact popover to move the track — right where the
  # folder is shown, reusing the same `move_track` the ⋯ menu uses. A backdrop
  # closes it on an outside click. Nothing extra shows until you click, so rows
  # stay clean.
  attr :track, :map, required: true
  attr :open?, :boolean, required: true
  attr :folders, :list, required: true

  defp folder_cell(assigns) do
    ~H"""
    <div class="relative hidden min-w-0 lg:block">
      <button
        type="button"
        phx-click="folder_menu_toggle"
        phx-value-id={@track.id}
        aria-haspopup="true"
        aria-expanded={to_string(@open?)}
        class="group/fld inline-flex max-w-full items-center gap-1 rounded-sm text-left"
        title="Mudar a pasta"
      >
        <.folder_badge :if={@track.genre_folder} folder={@track.genre_folder} />
        <span
          :if={is_nil(@track.genre_folder)}
          class="rounded-sm border border-dashed border-white/15 px-1.5 py-[2px] text-[10px] text-ink-faint group-hover/fld:border-white/30 group-hover/fld:text-ink-muted"
        >
          sem pasta
        </span>
        <span
          class="text-[9px] text-ink-faint opacity-0 transition-opacity group-hover/fld:opacity-100"
          aria-hidden="true"
        >
          ▾
        </span>
      </button>
      <%= if @open? do %>
        <div
          class="fixed inset-0 z-30"
          phx-click="close_folder_menu"
          phx-window-keydown="close_folder_menu"
          phx-key="Escape"
          aria-hidden="true"
        >
        </div>
        <div class="absolute left-0 top-7 z-40 max-h-64 w-48 overflow-auto rounded-lg border border-white/10 bg-surface py-1 shadow-xl shadow-black/40">
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
        </div>
      <% end %>
    </div>
    """
  end

  defp track_path(id, "/"), do: ~p"/track/#{id}"
  defp track_path(id, library), do: ~p"/track/#{id}?#{%{library: library}}"

  # The per-row ⋯ popover: move-to-folder, "Parecidas", and open. A full-screen
  # backdrop (rendered only when open) closes it on an outside click.
  attr :track, :map, required: true
  attr :open?, :boolean, required: true
  attr :folders, :list, required: true
  attr :library_path, :string, required: true

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
        aria-label={"Ações de #{@track.tag_title || @track.filename}"}
      >
        ⋯
      </button>
      <%= if @open? do %>
        <div
          class="fixed inset-0 z-30"
          phx-click="close_row_menu"
          phx-window-keydown="close_row_menu"
          phx-key="Escape"
          aria-hidden="true"
        >
        </div>
        <div class="absolute right-0 top-8 z-40 max-h-64 w-52 overflow-y-auto rounded-lg border border-white/10 bg-surface py-1 shadow-xl shadow-black/40">
          <div class="lg:hidden">
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
          </div>
          <button
            type="button"
            phx-click="similar_to"
            phx-value-track_id={@track.id}
            class="flex w-full items-center px-3 py-1.5 text-left text-body-sm text-ink-secondary hover:bg-white/6 hover:text-ink"
          >
            Buscar faixas parecidas
          </button>
          <.link
            navigate={track_path(@track.id, @library_path)}
            class="flex w-full items-center px-3 py-1.5 text-body-sm text-ink-secondary hover:bg-white/6 hover:text-ink"
          >
            Abrir ficha
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

  attr :filtered?, :boolean, required: true

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-3 px-4 py-16 text-center">
      <span class="hero-musical-note size-8 text-ink-faint" aria-hidden="true" />
      <p class="text-body text-ink-muted">
        {if @filtered?,
          do: "Nenhuma faixa com esses filtros.",
          else: "Ainda não há faixas na biblioteca."}
      </p>
      <button
        :if={@filtered?}
        phx-click="clear_filters"
        class="rounded-md border border-white/10 bg-input px-3 py-2 text-body-sm text-ink hover:bg-white/8"
      >
        Limpar filtros
      </button>
      <.link
        :if={!@filtered?}
        navigate={~p"/importados?origem=local"}
        class="rounded-md bg-primary-deep px-3 py-2 text-body-sm font-semibold text-white"
      >
        Importar arquivos
      </.link>
    </div>
    """
  end

  # Confirmation bar around a move: "movendo…" while the worker runs, then the
  # result carrying the batch_id behind a "Desfazer", then "desfazendo…".
  attr :toast, :any, required: true

  defp move_toast(assigns) do
    {label, undoable} =
      case assigns.toast do
        {:moving, n} -> {"Movendo #{n} faixa(s) em segundo plano…", false}
        :undoing -> {"Desfazendo o último lote…", false}
        {:moved, n, _batch_id} -> {move_toast_label(n), n > 0}
      end

    assigns = assign(assigns, label: label, undoable: undoable)

    ~H"""
    <div class="flex items-center justify-between gap-3 border-b border-primary/30 bg-primary/10 px-3 py-2 lg:px-5">
      <p class="text-body-sm text-ink">
        {@label}
      </p>
      <div class="flex items-center gap-3">
        <button
          :if={@undoable}
          phx-click="undo_move"
          class="rounded-md border border-primary/40 bg-primary/15 px-2.5 py-1 text-body-sm font-semibold text-primary hover:bg-primary/25"
        >
          Desfazer
        </button>
        <button
          phx-click="dismiss_move_toast"
          aria-label="Fechar aviso"
          class="text-body-sm text-ink-muted hover:text-ink"
        >
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
    <div class="border-t border-primary/30 bg-primary/10 px-3 py-2.5 lg:px-5">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <span class="text-body-sm font-semibold text-ink">
          {@count} {if @count == 1, do: "selecionada", else: "selecionadas"}
        </span>

        <form
          id="batch-move"
          phx-change="move_selected"
          class="flex min-w-0 flex-wrap items-center gap-2"
        >
          <label class="text-body-sm text-ink-muted">Mover para</label>
          <select
            name="folder"
            aria-label="Mover para a pasta"
            class="h-8 max-w-full rounded-md border border-white/10 bg-input px-2 py-1 text-body-sm focus:border-primary/50"
          >
            <option value="">escolher…</option>
            <option :for={folder <- @folders} value={folder.key}>{folder.display_name}</option>
          </select>
        </form>

        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <span class="text-body-sm text-ink-muted">Avaliar</span>
          <div class="flex flex-wrap gap-0.5">
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

  defp chip_class(active?) do
    [
      "max-w-full break-words rounded-sm border px-2 py-1.5 text-left text-[11px] font-semibold [overflow-wrap:anywhere] transition-colors",
      active? && "border-primary/60 bg-primary/20 text-ink",
      !active? && "border-white/8 bg-input text-ink-muted hover:border-white/20"
    ]
  end

  # The row grid: an optional leading checkbox column in select mode, the cover,
  # the data columns, and a trailing ⋯ action column.
  defp row_selected?(selected, id), do: MapSet.member?(selected, id)

  defp bpm(track), do: effective_bpm(track)
  defp camelot(track), do: effective_camelot(track)

  # --- Camelot wheel (Tom filter) ---------------------------------------------

  attr :selected, :string, default: nil
  attr :compatible?, :boolean, default: false

  defp camelot_wheel(assigns) do
    neighbors = wheel_neighbors(assigns.selected, assigns.compatible?)
    assigns = assign(assigns, wedges: camelot_wedges(), neighbors: neighbors)

    ~H"""
    <form id="library-wheel-choice" phx-change="choose_camelot">
      <select
        id="library-wheel-code"
        name="code"
        aria-label="Tom Camelot"
        class="h-8 w-full rounded-md border border-white/8 bg-input px-2 py-1.5 font-mono text-body text-ink"
      >
        <option value="" selected={is_nil(@selected)}>Qualquer tom</option>
        <option :for={w <- @wedges} value={w.code} selected={w.code == @selected}>{w.code}</option>
      </select>
    </form>
    <svg
      viewBox="0 0 280 280"
      class="mx-auto w-full max-w-[300px]"
      aria-hidden="true"
      focusable="false"
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
        class="pointer-events-none fill-ink font-mono"
      >
        {@selected}
      </text>
      <text
        x="140"
        y="160"
        text-anchor="middle"
        font-size="11"
        fill="#7d818c"
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
end
