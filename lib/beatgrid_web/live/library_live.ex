defmodule BeatgridWeb.LibraryLive do
  @moduledoc "Biblioteca — the filterable track table."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.{GenreFolders, TrackQuery}

  @confidences [{"alta", :high}, {"média", :medium}, {"baixa", :low}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Biblioteca", folders: GenreFolders.list(), filters: %{})
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

  def handle_event("filter", params, socket) do
    filters =
      socket.assigns.filters
      |> put_filter(:search, params["search"])
      |> put_filter(:rating_min, params["rating_min"])
      |> put_filter(:bpm_min, params["bpm_min"])
      |> put_filter(:bpm_max, params["bpm_max"])

    {:noreply, socket |> assign(filters: filters) |> load_tracks()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(filters: %{}) |> load_tracks()}
  end

  defp load_tracks(socket), do: assign(socket, tracks: TrackQuery.library(socket.assigns.filters))

  defp update_filter(socket, key, nil),
    do: assign(socket, filters: Map.delete(socket.assigns.filters, key))

  defp update_filter(socket, key, val),
    do: assign(socket, filters: Map.put(socket.assigns.filters, key, val))

  defp toggle(current, val), do: if(current == val, do: nil, else: val)
  defp put_filter(filters, key, val) when val in [nil, ""], do: Map.delete(filters, key)
  defp put_filter(filters, key, val), do: Map.put(filters, key, val)

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:biblioteca}>
      <div class="flex h-screen flex-col">
        <header class="flex items-center justify-between gap-4 border-b border-white/6 bg-rail px-5 py-3">
          <div class="flex items-baseline gap-3">
            <h2 class="text-[22px] font-semibold">Biblioteca</h2>
            <span class="font-mono text-body-sm text-ink-muted">{length(@tracks)} faixas</span>
          </div>
          <form id="library-search" phx-change="filter" class="w-72">
            <input
              type="search"
              name="search"
              value={@filters[:search] || ""}
              placeholder="Buscar artista ou título…"
              class="w-full rounded-md border border-white/8 bg-input px-3 py-1.5 text-body placeholder:text-ink-faint focus:border-primary/50 focus:outline-none"
            />
          </form>
        </header>

        <div class="flex min-h-0 flex-1">
          <aside class="w-60 shrink-0 overflow-y-auto border-r border-white/6 bg-rail px-4 py-4">
            <.filters_panel filters={@filters} folders={@folders} />
          </aside>

          <section class="min-w-0 flex-1 overflow-y-auto px-5 py-4">
            <.track_table :if={@tracks != []} tracks={@tracks} />
            <.empty_state :if={@tracks == []} />
          </section>
        </div>
      </div>
    </.app_shell>
    """
  end

  attr :filters, :map, required: true
  attr :folders, :list, required: true

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

    <p class="mt-4 mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Pasta</p>
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

    <form id="library-filters" phx-change="filter" class="mt-4 space-y-3">
      <div>
        <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
          Nota mínima
        </p>
        <input
          type="number"
          name="rating_min"
          min="0"
          max="10"
          value={@filters[:rating_min]}
          class="w-20 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-body-sm focus:border-primary/50 focus:outline-none"
        />
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

  defp track_table(assigns) do
    ~H"""
    <div class="space-y-1">
      <div
        class="grid items-center gap-2 px-1.5 pb-2 text-[10px] font-semibold uppercase tracking-wider text-ink-faint"
        style={grid_cols()}
      >
        <span></span>
        <span>Faixa</span>
        <span>Pasta</span>
        <span class="text-right">BPM</span>
        <span>Tom</span>
        <span>Energia</span>
        <span class="text-right">Nota</span>
        <span class="text-right">Sinal</span>
      </div>
      <.link
        :for={track <- @tracks}
        navigate={~p"/track/#{track.id}"}
        class="grid items-center gap-2 rounded-lg px-1.5 py-1.5 hover:bg-surface-2"
        style={grid_cols()}
      >
        <.cover artist={track.tag_artist} size={38} />
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
    </div>
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

  defp chip_class(active?) do
    [
      "rounded-sm border px-[9px] py-[5px] text-[11px] font-semibold transition-colors",
      active? && "border-primary/60 bg-primary/20 text-ink",
      !active? && "border-white/8 bg-input text-ink-muted hover:border-white/20"
    ]
  end

  defp grid_cols, do: "grid-template-columns:38px 1fr 130px 52px 56px 80px 52px 100px"

  defp bpm(%{soundcharts_song: %{tempo_bpm: bpm}}) when is_number(bpm), do: round(bpm)
  defp bpm(_track), do: "—"

  defp camelot(%{soundcharts_song: %{camelot: c}}), do: c
  defp camelot(_track), do: nil

  defp energy_pct(%{soundcharts_song: %{energy: e}}) when is_number(e), do: round(e * 100)
  defp energy_pct(_track), do: 0
end
