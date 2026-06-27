defmodule BeatgridWeb.LibraryLive do
  @moduledoc "Biblioteca — the filterable track table."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library
  alias Beatgrid.Library.{GenreFolders, TrackQuery}
  alias Beatgrid.Workers.ImportWorker

  @confidences [{"alta", :high}, {"média", :medium}, {"baixa", :low}]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe_import()

    {:ok,
     socket
     |> assign(
       page_title: "Biblioteca",
       folders: GenreFolders.list(),
       filters: %{},
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
    <.app_shell active={:biblioteca} socket={@socket}>
      <div class="flex h-screen flex-col">
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

      <.import_modal :if={@import && @import.open} import={@import} />
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
      <div
        :for={track <- @tracks}
        class="grid items-center gap-2 rounded-lg px-1.5 py-1.5 hover:bg-surface-2"
        style={grid_cols()}
      >
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
      </div>
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

  defp grid_cols, do: "grid-template-columns:38px 1fr 130px 52px 56px 80px 52px 100px"

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
