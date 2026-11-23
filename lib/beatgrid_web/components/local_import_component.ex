defmodule BeatgridWeb.LocalImportComponent do
  @moduledoc "Handles preview, confirmation, and live progress for local file imports."
  use BeatgridWeb, :live_component

  alias Beatgrid.Library
  alias Beatgrid.Library.SourceBrowser
  alias Beatgrid.Workers.ImportWorker

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       local_import: %{source: "", loading: false},
       local_progress: %{},
       local_result: nil
     )}
  end

  @impl true
  def update(%{active: active, progress_event: progress} = assigns, socket) do
    socket =
      if progress != socket.assigns[:progress_event],
        do: track_local_progress(socket, progress),
        else: socket

    socket = assign(socket, assigns)

    if active and is_nil(socket.assigns.local_import[:browse]) do
      {:ok, update(socket, :local_import, &browse(&1, SourceBrowser.start_dir()))}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} hidden={!@active} class="max-w-[1100px]">
      <.local_import_panel :if={@active} import={@local_import} target={@myself} />
      <.local_import_activity
        :if={@active}
        progress={@local_progress}
        result={@local_result}
        target={@myself}
      />
    </div>
    """
  end

  @impl true
  def handle_event("edit_local_import", %{"source" => source} = params, socket)
      when is_binary(source) do
    state = local_draft(socket, source, params)

    {:noreply,
     socket
     |> cancel_async(:local_preview)
     |> assign(local_import: state)}
  end

  def handle_event("preview_import", %{"source" => source} = params, socket)
      when is_binary(source) do
    source = String.trim(source)
    socket = assign(socket, local_import: local_draft(socket, source, params))

    if source == "" do
      {:noreply,
       socket
       |> cancel_async(:local_preview)
       |> update(:local_import, &Map.put(&1, :error, "Cole um caminho."))}
    else
      {:noreply, start_local_preview(socket, source)}
    end
  end

  def handle_event("browse_to", %{"dir" => dir}, socket) when is_binary(dir),
    do: {:noreply, update(socket, :local_import, &browse(&1, dir))}

  def handle_event("browse_pick", %{"file" => file}, socket) when is_binary(file),
    do: {:noreply, start_local_preview(socket, file)}

  def handle_event("browse_import_here", _params, socket) do
    case socket.assigns.local_import[:browse] do
      %{dir: dir} -> {:noreply, start_local_preview(socket, dir)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event(
        "run_import",
        params,
        %{assigns: %{active: true, local_import: %{rows: rows}}} = socket
      )
      when is_list(rows) do
    items = items_from_params(params, rows)

    case items do
      [] -> {:noreply, socket}
      _ -> {:noreply, enqueue_local_import(socket, items)}
    end
  end

  def handle_event("run_import", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_import_toast", _params, socket),
    do: {:noreply, assign(socket, local_result: nil)}

  defp local_draft(socket, source, params) do
    Map.merge(socket.assigns.local_import, %{
      source: source,
      ai: params["ai"] == "on",
      soundcharts: params["soundcharts"] == "on",
      loading: false,
      error: nil,
      rows: nil
    })
  end

  defp start_local_preview(socket, source) do
    ai? = socket.assigns.local_import[:ai] == true

    socket
    |> cancel_async(:local_preview)
    |> update(
      :local_import,
      &Map.merge(&1, %{source: source, loading: true, error: nil, rows: nil})
    )
    |> start_async(:local_preview, fn -> Library.preview_import(source, ai: ai?) end)
  end

  defp browse(state, dir) do
    listing =
      case SourceBrowser.list(dir) do
        {:ok, listing} ->
          Map.put(listing, :error, nil)

        {:error, _reason} ->
          %{
            dir: dir,
            parent: Path.dirname(dir),
            dirs: [],
            files: [],
            error: "Não deu para ler esta pasta."
          }
      end

    Map.put(state, :browse, listing)
  end

  defp enqueue_local_import(socket, items) do
    batch_id = Uniq.UUID.uuid7()
    soundcharts? = socket.assigns.local_import[:soundcharts] == true

    case ImportWorker.enqueue(items, batch_id, resolve_soundcharts: soundcharts?) do
      {:ok, _job} ->
        progress = %{batch_id: batch_id, status: :queued, done: 0, total: length(items)}

        socket
        |> update(
          :local_import,
          &Map.merge(&1, %{source: "", rows: nil, error: nil, ai: false, soundcharts: false})
        )
        |> assign(local_result: nil)
        |> track_local_progress(progress)

      {:error, _reason} ->
        update(
          socket,
          :local_import,
          &Map.put(&1, :error, "Falha ao colocar as faixas na fila. Tente novamente.")
        )
    end
  end

  defp track_local_progress(socket, %{status: :done} = progress) do
    socket
    |> update(:local_progress, &Map.delete(&1, progress.batch_id))
    |> assign(local_result: progress)
  end

  defp track_local_progress(socket, nil), do: socket

  defp track_local_progress(socket, progress),
    do: update(socket, :local_progress, &Map.put(&1, progress.batch_id, progress))

  # Only reviewed, non-duplicate paths can reach the copying worker.
  defp items_from_params(%{"items" => edits}, rows) when is_map(edits) do
    for {row, index} <- Enum.with_index(rows),
        not row.duplicate,
        edit = edits[to_string(index)],
        is_map(edit),
        edit["source_path"] == row.source_path,
        artist = Map.get(edit, "artist", ""),
        title = Map.get(edit, "title", ""),
        is_binary(artist) and is_binary(title) do
      %{
        "source_path" => row.source_path,
        "sha256" => row.sha256,
        "artist" => String.trim(artist),
        "title" => String.trim(title)
      }
    end
  end

  defp items_from_params(_params, _rows), do: []

  @impl true
  def handle_async(
        :local_preview,
        _result,
        %{assigns: %{local_import: %{loading: false}}} = socket
      ),
      do: {:noreply, socket}

  def handle_async(:local_preview, result, socket) do
    outcome =
      case result do
        {:ok, {:ok, rows}} -> %{rows: rows}
        {:ok, {:error, :not_found}} -> %{error: "Caminho não encontrado ou não é áudio."}
        _ -> %{error: "Falha ao pré-visualizar. Tente novamente."}
      end

    {:noreply,
     update(socket, :local_import, &(&1 |> Map.merge(outcome) |> Map.put(:loading, false)))}
  end

  attr :import, :map, required: true

  attr :target, :any, required: true

  defp local_import_panel(assigns) do
    ~H"""
    <section
      class="rounded-lg border border-white/8 bg-surface p-4"
      aria-labelledby="local-import-title"
    >
      <h2 id="local-import-title" class="mb-3 text-[18px] font-semibold">
        Importar pasta ou arquivo
      </h2>

      <form
        id="import-source"
        phx-target={@target}
        phx-change="edit_local_import"
        phx-submit="preview_import"
        class="space-y-2"
      >
        <label for="local-source" class="block text-body font-semibold">Caminho da pasta ou arquivo</label>
        <input
          id="local-source"
          type="text"
          name="source"
          value={@import[:source]}
          placeholder="Cole um caminho ou escolha abaixo"
          class="w-full rounded-md border border-white/8 bg-input px-3 py-2 text-body"
        />
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <label class="flex items-center gap-2 text-body-sm text-ink-secondary">
            <input type="checkbox" name="ai" checked={@import[:ai]} /> Refinar títulos com IA
          </label>
          <label class="flex items-center gap-2 text-body-sm text-ink-secondary">
            <input type="checkbox" name="soundcharts" checked={@import[:soundcharts]} />
            Resolver no Soundcharts depois (gasta cota)
          </label>
          <button
            type="submit"
            disabled={@import[:loading]}
            class="ml-auto rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm font-semibold text-ink-secondary hover:text-ink disabled:opacity-40"
          >
            Pré-visualizar caminho
          </button>
        </div>
      </form>

      <.source_browser browse={@import.browse} target={@target} />

      <p :if={@import[:error]} role="alert" class="mt-3 text-body-sm text-coral-soft">
        {@import.error}
      </p>

      <p :if={@import[:loading]} role="status" class="mt-4 text-body-sm text-ink-muted">
        Pré-visualizando…
      </p>

      <.preview_table
        :if={@import[:rows]}
        rows={@import.rows}
        soundcharts={@import[:soundcharts]}
        target={@target}
      />
    </section>
    """
  end

  attr :progress, :map, required: true
  attr :result, :map, default: nil

  attr :target, :any, required: true

  defp local_import_activity(assigns) do
    ~H"""
    <section id="local-import-activity" class="mt-4" aria-labelledby="local-activity-title">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 id="local-activity-title" class="text-body font-semibold">Cópia de arquivos</h2>
        <.link
          navigate={~p"/jobs?worker=ImportWorker"}
          class="text-body-sm text-primary-soft underline"
        >
          Ver fila e tentativas
        </.link>
      </div>
      <p :if={@progress == %{} and !@result} class="mt-2 text-body-sm text-ink-muted">
        Nenhuma cópia em andamento.
      </p>

      <div
        :for={{batch, progress} <- Enum.sort(@progress)}
        id={"local-import-#{batch}"}
        class="flex items-center gap-2 py-2"
      >
        <p role="status" class="font-mono text-caption text-ink-muted">{progress_label(progress)}</p>
        <div aria-hidden="true" class="h-1.5 w-32 rounded-full bg-white/5">
          <div
            class="h-full rounded-full bg-primary motion-safe:transition-[width]"
            style={"width:#{progress_pct(progress)}%"}
          />
        </div>
      </div>

      <div :if={@result} class="flex flex-wrap items-center gap-3 border-b border-white/8 py-2">
        <p role="status" class="grow text-body-sm text-ink">{import_summary(@result)}</p>
        <.link
          :if={@result.imported > 0}
          navigate={~p"/"}
          class="text-body-sm text-primary-soft underline"
        >
          Ver Biblioteca
        </.link>
        <button
          type="button"
          phx-target={@target}
          phx-click="dismiss_import_toast"
          class="text-body-sm text-ink-muted hover:text-ink"
        >
          Fechar aviso
        </button>
      </div>
    </section>
    """
  end

  defp import_summary(%{failed: failed} = result) when failed > 0 do
    files = result.failures |> Enum.take(3) |> Enum.map_join(", ", & &1.file)

    "#{result.imported} importada(s), #{result.skipped} duplicada(s), #{failed} com falha (#{files}). Confira os arquivos e tente novamente."
  end

  defp import_summary(%{imported: n}) when n > 0, do: "#{n} faixa(s) importada(s)."
  defp import_summary(_result), do: "Nada novo para importar."

  # Server-side folder browser: the app is single-user and local, so it walks the
  # DJ's own disk — no upload, no typing paths by hand. Listing is extension-only
  # (cheap); the probe happens in the preview.
  attr :browse, :map, required: true

  attr :target, :any, required: true

  defp source_browser(assigns) do
    ~H"""
    <div id="import-browser" class="mt-3 rounded-lg border border-white/8">
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-white/5 px-3 py-2">
        <p class="min-w-0 truncate font-mono text-caption text-ink-muted" title={@browse.dir}>
          {@browse.dir}
        </p>
        <button
          phx-target={@target}
          phx-click="browse_import_here"
          class="min-h-11 shrink-0 rounded-md bg-primary/15 sm:min-h-0 px-2.5 py-1 text-body-sm font-semibold text-primary hover:bg-primary/25"
        >
          Pré-visualizar esta pasta
        </button>
      </div>

      <p :if={@browse.error} class="px-3 py-2 text-body-sm text-ink-muted">{@browse.error}</p>

      <div class="max-h-56 divide-y divide-white/5 overflow-y-auto">
        <button
          :if={@browse.parent}
          phx-target={@target}
          phx-click="browse_to"
          phx-value-dir={@browse.parent}
          class="block min-h-11 w-full sm:min-h-0 px-3 py-1.5 text-left text-body-sm text-ink-muted hover:bg-white/5 hover:text-ink"
        >
          Pasta acima
        </button>
        <button
          :for={dir <- @browse.dirs}
          phx-target={@target}
          phx-click="browse_to"
          phx-value-dir={dir.path}
          class="block min-h-11 w-full sm:min-h-0 truncate px-3 py-1.5 text-left text-body-sm text-ink-secondary hover:bg-white/5 hover:text-ink"
        >
          {dir.name}/
        </button>
        <button
          :for={file <- @browse.files}
          phx-target={@target}
          phx-click="browse_pick"
          phx-value-file={file.path}
          class="block min-h-11 w-full sm:min-h-0 truncate px-3 py-1.5 text-left text-body-sm text-ink hover:bg-primary/10"
        >
          {file.name}
        </button>
        <p
          :if={!@browse.error && @browse.dirs == [] && @browse.files == []}
          class="px-3 py-2 text-body-sm text-ink-faint"
        >
          Nada importável aqui — entre numa subpasta ou cole um caminho.
        </p>
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :soundcharts, :boolean, default: false

  attr :target, :any, required: true

  defp preview_table(assigns) do
    assigns =
      assigns
      |> assign(:new_rows, Enum.reject(assigns.rows, & &1.duplicate))
      |> assign(:dupes, Enum.count(assigns.rows, & &1.duplicate))

    ~H"""
    <div class="mt-5">
      <p class="mb-2 text-body-sm text-ink-muted" role="status">
        {length(@new_rows)} nova(s), {@dupes} duplicada(s)
      </p>

      <form id="import-run" phx-target={@target} phx-submit="run_import" class="space-y-1">
        <div
          :for={{row, i} <- Enum.with_index(@rows)}
          class={[
            "grid grid-cols-2 items-center gap-2 rounded-lg px-2 py-2 lg:grid-cols-[1fr_1fr_1.2fr_60px_60px]",
            row.duplicate && "opacity-50",
            !row.duplicate && "bg-base"
          ]}
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
              aria-label={"Artista de #{row.filename}"}
              placeholder="Artista"
              class="w-full rounded-md border border-white/8 bg-input px-2 py-1 text-body-sm"
            />
            <input
              type="text"
              name={"items[#{i}][title]"}
              value={row.title}
              aria-label={"Título de #{row.filename}"}
              placeholder="Título"
              class="w-full rounded-md border border-white/8 bg-input px-2 py-1 text-body-sm"
            />
          <% end %>
          <span class="col-span-2 min-w-0 text-caption text-ink-faint lg:col-span-1">
            <span class="block truncate" title={row.filename}>{row.filename}</span>
            <span
              :if={row.duplicate}
              class="inline-block rounded bg-white/8 px-1.5 py-px text-[10px] text-ink-muted"
            >
              duplicada — será pulada
            </span>
            <span
              :if={row.near_dup}
              class="inline-block rounded bg-amber/15 px-1.5 py-px text-[10px] font-semibold text-amber"
              title="Já existe uma faixa com o mesmo artista e título (versão diferente). Você ainda pode importar."
            >
              parecida já existe
            </span>
          </span>
          <span class="text-right font-mono text-caption text-ink-muted">{duration(row.duration_ms)}</span>
          <span class="text-right font-mono text-caption text-ink-faint">{format_label(row.format)}</span>
        </div>

        <div :if={@new_rows != []} class="flex justify-end pt-3">
          <button class="rounded-md bg-primary-deep px-4 py-2 text-body-sm font-semibold text-white">
            Importar {length(@new_rows)} faixa(s){if @soundcharts, do: " + Soundcharts", else: ""}
          </button>
        </div>
        <p :if={@rows == []} class="pt-3 text-body-sm text-ink-muted">
          Nenhum arquivo de áudio encontrado nesta pasta.
        </p>
        <p :if={@rows != [] and @new_rows == []} class="pt-3 text-body-sm text-ink-faint">
          Nada novo para importar — tudo já está na biblioteca.
        </p>
      </form>
    </div>
    """
  end

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
