defmodule BeatgridWeb.ImportsLive do
  @moduledoc "Reviews online imports, follows download batches, and groups imported tracks into playlists."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.{Jobs, Library, Repertoire}
  alias Beatgrid.Library.{TrackQuery, Tracks}
  alias Beatgrid.Spotify.Playlist
  alias Beatgrid.YouTube
  alias Beatgrid.YouTube.{Playlists, Preview}

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      YouTube.subscribe()
      schedule_refresh()
    end

    recommendation =
      case Ecto.UUID.cast(params["recomendacao"]) do
        {:ok, id} -> Repertoire.get_recommendation(id)
        :error -> nil
      end

    {:ok,
     socket
     |> assign(
       page_title: "Importados",
       filters: %{},
       sort: :recent,
       expanded: MapSet.new(),
       urls: "",
       rows: [],
       spotify: nil,
       loading: false,
       error: nil,
       search: nil,
       recommendation: recommendation,
       selected: MapSet.new()
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    batch =
      case Ecto.UUID.cast(params["lote"]) do
        {:ok, id} -> id
        :error -> nil
      end

    {:noreply, socket |> assign(batch: batch) |> load_activity()}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh_downloads, 3_000)

  defp load_activity(socket) do
    jobs =
      case socket.assigns.batch do
        nil -> Jobs.list_recent(worker: "DownloadWorker", limit: 8)
        id -> Jobs.downloads_in_batch(id)
      end

    assign(socket, downloads: jobs, completed: Enum.count(jobs, &(&1.state == "completed")))
  end

  @impl true
  def handle_info(:refresh_downloads, socket) do
    schedule_refresh()
    {:noreply, load_activity(socket)}
  end

  def handle_info({:youtube_tick}, socket), do: {:noreply, socket |> load_activity() |> load()}

  defp load(socket) do
    filters = Map.put(socket.assigns.filters, :sort, socket.assigns.sort)

    %{playlists: playlists, singles: singles} =
      Playlists.group(TrackQuery.youtube_imports(filters))

    assign(socket, playlists: playlists, singles: singles)
  end

  @impl true
  def handle_event("toggle_filter", %{"key" => key}, socket)
      when key in ~w(unfiled unresolved gold) do
    k = String.to_existing_atom(key)
    filters = Map.update(socket.assigns.filters, k, true, fn v -> if v, do: nil, else: true end)
    {:noreply, socket |> assign(filters: filters) |> load()}
  end

  def handle_event("toggle_filter", _params, socket), do: {:noreply, socket}

  def handle_event("sort", %{"by" => by}, socket) when by in ~w(recent views published) do
    {:noreply, socket |> assign(sort: String.to_existing_atom(by)) |> load()}
  end

  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("edit_links", %{"urls" => urls}, socket) do
    {:noreply,
     socket
     |> cancel_async(:preview)
     |> assign(urls: urls, rows: [], loading: false, error: nil, search: nil)}
  end

  def handle_event("preview_links", %{"urls" => input}, socket) do
    urls = String.trim(input)
    socket = assign(socket, urls: urls, search: nil, recommendation: nil)

    case Playlist.id(urls) do
      {:ok, id} ->
        {:noreply,
         start_review(assign(socket, spotify: nil), :spotify, fn -> Playlist.preview(id) end)}

      :invalid ->
        {:noreply, start_review(socket, :videos, fn -> Preview.list(urls) end)}
    end
  end

  def handle_event("find_version", %{"index" => index}, socket) do
    tracks = if socket.assigns.spotify, do: socket.assigns.spotify.tracks, else: []

    with true <- is_binary(index),
         {i, ""} when i >= 0 <- Integer.parse(index),
         %{artist: artist, title: title} <- Enum.at(tracks, i) do
      {:noreply, search_versions(assign(socket, recommendation: nil), artist <> " " <> title)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("find_recommendation", _, %{assigns: %{recommendation: rec}} = socket)
      when not is_nil(rec) do
    {:noreply, search_versions(socket, rec.youtube_query || "#{rec.artist} #{rec.song}")}
  end

  def handle_event("select_downloads", params, socket) do
    {:noreply, assign(socket, selected: MapSet.new(List.wrap(params["ids"])))}
  end

  def handle_event("confirm_downloads", params, socket) do
    ids = List.wrap(params["ids"])
    recommendation_id = socket.assigns.recommendation && socket.assigns.recommendation.id

    case Preview.confirm(socket.assigns.rows, ids, recommendation_id) do
      {:error, :empty_selection} ->
        {:noreply, assign(socket, error: "Selecione ao menos uma faixa.")}

      {:ok, batch} ->
        {:noreply,
         socket
         |> assign(
           rows: [],
           urls: "",
           search: nil,
           selected: MapSet.new(),
           error: nil,
           recommendation: nil
         )
         |> push_patch(to: ~p"/importados?lote=#{batch}")}

      {:error, _} ->
        {:noreply, assign(socket, error: "Falha ao colocar as faixas na fila. Tente novamente.")}
    end
  end

  def handle_event("toggle_playlist", %{"key" => key}, socket) do
    {:noreply, update(socket, :expanded, &toggle(&1, key))}
  end

  def handle_event("create_set", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.playlists, &(&1.key == key)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Playlist não encontrada — atualize a página.")}

      playlist ->
        case Playlists.create_set(playlist) do
          {:ok, set} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Set “#{set.name}” criado com #{playlist.count} faixas e transições sugeridas."
             )
             |> push_navigate(to: ~p"/set/#{set.id}")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Não deu pra criar o set desta playlist — tente de novo.")
             |> load()}
        end
    end
  end

  def handle_event("toggle_gold", %{"id" => id}, socket) do
    case Tracks.get(id) do
      nil -> :ok
      track -> Library.toggle_gold(track)
    end

    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Tracks.get(id) do
      nil -> :ok
      track -> Library.hard_delete(track)
    end

    {:noreply, load(socket)}
  end

  defp search_versions(socket, query) do
    start_review(assign(socket, search: query), :search, fn -> Preview.search(query) end)
  end

  defp start_review(socket, kind, fun) do
    socket
    |> assign(loading: true, error: nil, rows: [], selected: MapSet.new())
    |> start_async(:preview, fn -> {kind, fun.()} end)
  end

  @impl true
  def handle_async(:preview, _, %{assigns: %{loading: false}} = socket), do: {:noreply, socket}

  def handle_async(:preview, {:ok, {:spotify, {:ok, catalog}}}, socket),
    do: {:noreply, assign(socket, loading: false, spotify: catalog)}

  def handle_async(:preview, {:ok, {kind, {:ok, rows}}}, socket) do
    selected = if kind == :videos, do: MapSet.new(rows, & &1.id), else: MapSet.new()
    {:noreply, assign(socket, loading: false, rows: rows, selected: selected)}
  end

  def handle_async(:preview, {:ok, {_, {:error, %Beatgrid.Error{message: message}}}}, socket),
    do: {:noreply, assign(socket, loading: false, error: message)}

  def handle_async(:preview, _, socket),
    do:
      {:noreply,
       assign(socket,
         loading: false,
         error: "Não foi possível consultar as faixas. Tente novamente."
       )}

  defp download_issue(%{state: state, errors: errors})
       when state in ["retryable", "discarded", "cancelled"] do
    message = get_in(List.last(errors), ["error"]) || ""

    cond do
      message =~ "429" ->
        "O YouTube limitou o acesso nesta conexão (429)."

      message =~ "403" ->
        "O YouTube recusou o áudio (403). Confira a versão do yt-dlp e tente novamente."

      message =~ "verification_required" ->
        "O YouTube pediu verificação para este vídeo."

      message =~ "video_unavailable" ->
        "O vídeo está privado, restrito ou indisponível."

      message != "" ->
        "Consulte a última tentativa na fila."

      true ->
        nil
    end
  end

  defp download_issue(_), do: nil

  defp download_state("available"), do: "Na fila"
  defp download_state("executing"), do: "Baixando"
  defp download_state("completed"), do: "Importada"
  defp download_state("retryable"), do: "Aguardando nova tentativa"
  defp download_state("scheduled"), do: "Agendada"
  defp download_state("cancelled"), do: "Cancelada"
  defp download_state("suspended"), do: "Pausada"
  defp download_state(_), do: "Falhou"

  defp toggle(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:importados} socket={@socket}>
      <div class="px-3 py-4 sm:px-6 sm:py-5">
        <header class="mb-4 flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-[22px] font-semibold">Importados</h1>
          <.link navigate={~p"/?importar=1"} class="text-body-sm text-primary-soft underline">Importar arquivo local</.link>
        </header>
        <section
          class="mb-5 rounded-md border border-white/10 bg-surface p-4"
          aria-label="Importar de um link"
        >
          <form id="link-preview" phx-submit="preview_links" phx-change="edit_links">
            <label for="import-urls" class="block text-body font-semibold">Links do YouTube ou playlist do Spotify</label>
            <p id="link-hint" class="mb-2 text-body-sm text-ink-muted">
              Cole um link por linha. Para baixar uma playlist do YouTube, use o link da própria playlist.
            </p>
            <div class="flex flex-wrap items-end gap-2">
              <textarea
                id="import-urls"
                name="urls"
                rows="2"
                aria-describedby="link-hint"
                placeholder="https://…"
                class="min-w-0 grow rounded-sm border border-white/10 bg-input px-3 py-2 text-body"
              >{@urls}</textarea>
              <button
                type="submit"
                disabled={@loading}
                class="rounded-sm bg-primary-deep px-4 py-2 text-body-sm font-semibold text-white disabled:opacity-50"
              >Conferir links</button>
            </div>
          </form>
          <p :if={@recommendation} class="mt-3 text-body-sm">
            {@recommendation.artist} · {@recommendation.song}
            <button phx-click="find_recommendation" class="ml-2 text-primary-soft underline">Buscar versões</button>
          </p>
          <p :if={@loading} role="status" class="mt-3 text-body-sm text-ink-muted">
            Consultando faixas…
          </p>
          <p :if={@error} role="alert" class="mt-3 text-body-sm text-coral-soft">{@error}</p>

          <a
            :if={@search}
            href={"https://www.youtube.com/results?" <> URI.encode_query(%{"search_query" => @search})}
            target="_blank"
            rel="noopener"
            class="mt-2 inline-flex text-body-sm text-primary-soft underline"
          >
            Procurar “{@search}” no YouTube
          </a>

          <form
            :if={@rows != []}
            id="confirm-downloads"
            phx-change="select_downloads"
            phx-submit="confirm_downloads"
            class="mt-4 border-t border-white/10 pt-3"
          >
            <fieldset>
              <legend class="mb-2 text-body font-semibold">
                {if @search, do: "Versões para “#{@search}”", else: "Confira as faixas"}
              </legend>
              <div class="max-h-72 overflow-y-auto">
                <div :for={row <- @rows} class="flex items-center gap-3 border-b border-white/6 py-1">
                  <label class="flex min-w-0 grow items-center gap-2 py-2 text-body-sm">
                    <input
                      type="checkbox"
                      name="ids[]"
                      value={row.id}
                      checked={MapSet.member?(@selected, row.id)}
                    />
                    <span class="min-w-0 break-words">
                      {row.title}
                      <span :if={row.playlist_title} class="block text-caption text-ink-muted">{row.playlist_title} · faixa {row.playlist_index}</span>
                    </span>
                  </label>
                  <a
                    href={row.url}
                    target="_blank"
                    rel="noopener"
                    class="text-caption text-primary-soft underline"
                    aria-label={"Abrir #{row.title} no YouTube"}
                  >Ver vídeo</a>
                </div>
              </div>
            </fieldset>
            <button
              disabled={MapSet.size(@selected) == 0}
              class="mt-3 rounded-sm bg-primary-deep px-4 py-2 text-body-sm font-semibold text-white disabled:opacity-50"
            >
              Baixar {MapSet.size(@selected)} {if MapSet.size(@selected) == 1,
                do: "faixa",
                else: "faixas"}
            </button>
          </form>
          <section :if={@spotify} class="mt-4 border-t border-white/10 pt-3">
            <h2 class="text-body font-semibold">{@spotify.title}</h2>
            <p class="text-body-sm text-ink-muted">
              {length(@spotify.tracks)} faixas na prévia pública do Spotify. Escolha uma faixa para conferir as versões no YouTube.
            </p>
            <ol class="mt-2 max-h-80 list-decimal overflow-y-auto pl-6">
              <li
                :for={{track, index} <- Enum.with_index(@spotify.tracks)}
                class="border-b border-white/6 py-1 text-body-sm"
              >
                <div class="flex flex-wrap items-center justify-between gap-1">
                  <span>{track.title} · {track.artist}<.link
                    :if={track.library_id}
                    navigate={~p"/track/#{track.library_id}"}
                    class="block py-1 text-caption text-green underline"
                  >Abrir na biblioteca</.link></span>
                  <button
                    type="button"
                    phx-click="find_version"
                    phx-value-index={index}
                    aria-label={"Buscar versões de #{track.title}"}
                    class="py-2 text-primary-soft underline"
                  >Buscar versões</button>
                </div>
              </li>
            </ol>
          </section>
        </section>
        <section id="download-activity" class="mb-5">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-body font-semibold">
              {if @batch, do: "Lote de downloads", else: "Downloads recentes"}
            </h2>
            <.link
              navigate={~p"/jobs?worker=DownloadWorker"}
              class="text-body-sm text-primary-soft underline"
            >Ver fila e tentativas</.link>
          </div>
          <p :if={@batch && @downloads != []} class="mt-1 text-body-sm text-ink-muted" role="status">
            {@completed} de {length(@downloads)} concluídos.
            <.link patch={~p"/importados"} class="ml-2 text-primary-soft underline">Ver recentes</.link>
          </p>
          <p :if={@downloads == []} class="mt-2 text-body-sm text-ink-muted">
            Nenhum download recente.
          </p>
          <ul class="mt-1 max-h-80 overflow-y-auto">
            <li
              :for={job <- @downloads}
              class="flex flex-wrap items-baseline justify-between gap-x-3 border-b border-white/6 py-2 text-body-sm"
            >
              <span class="min-w-0 break-all">{job.args["title"] || job.args["video_id"] ||
                job.args["url"]}</span>
              <span class="font-mono text-caption text-ink-muted">{download_state(job.state)}</span>
              <span :if={issue = download_issue(job)} class="w-full text-caption text-amber">{issue}</span>
            </li>
          </ul>
        </section>
        <h2 class="mb-2 text-body font-semibold">Faixas importadas do YouTube</h2>
        <div class="mb-3 flex flex-wrap items-center gap-1.5">
          <button
            phx-click="toggle_filter"
            phx-value-key="unfiled"
            class={chip_class(@filters[:unfiled] == true)}
          >
            Não classificadas
          </button>
          <button
            phx-click="toggle_filter"
            phx-value-key="unresolved"
            class={chip_class(@filters[:unresolved] == true)}
          >
            Não resolvidas
          </button>
          <button
            phx-click="toggle_filter"
            phx-value-key="gold"
            class={chip_class(@filters[:gold] == true)}
          >
            ★ Ouro
          </button>
          <span class="ml-auto text-caption text-ink-faint">Ordenar:</span>
          <button phx-click="sort" phx-value-by="recent" class={chip_class(@sort == :recent)}>
            Recentes
          </button>
          <button phx-click="sort" phx-value-by="views" class={chip_class(@sort == :views)}>
            Views
          </button>
          <button phx-click="sort" phx-value-by="published" class={chip_class(@sort == :published)}>
            Idade
          </button>
        </div>

        <div
          :if={@playlists == [] and @singles == []}
          class="rounded-xl border border-white/6 bg-surface p-8 text-center text-ink-muted"
        >
          Nenhum importado do YouTube por aqui.
        </div>

        <div
          :for={pl <- @playlists}
          class="mb-2 overflow-hidden rounded-xl border border-white/8 bg-surface"
        >
          <div class="flex items-center gap-3 px-3 py-2.5">
            <button
              phx-click="toggle_playlist"
              phx-value-key={pl.key}
              class="flex size-6 shrink-0 items-center justify-center rounded text-ink-muted hover:bg-white/5 hover:text-ink"
              aria-label={"Expandir/recolher #{pl.title}"}
              title="Expandir/recolher"
            >
              {if MapSet.member?(@expanded, pl.key), do: "▾", else: "▸"}
            </button>
            <button
              phx-click="toggle_playlist"
              phx-value-key={pl.key}
              class="min-w-0 flex-1 text-left"
            >
              <div class="truncate text-body font-semibold text-ink">{pl.title}</div>
              <div class="text-caption text-ink-faint">{pl.count} faixas</div>
            </button>
            <button
              phx-click="create_set"
              phx-value-key={pl.key}
              class="shrink-0 rounded-md border border-primary/40 bg-primary/15 px-3 py-1.5 text-body-sm font-semibold text-primary hover:bg-primary/25"
              aria-label={"Criar set com #{pl.title}"}
              title="Criar um set com estas faixas, na ordem, com transições sugeridas"
            >
              Criar set
            </button>
          </div>
          <ul
            :if={MapSet.member?(@expanded, pl.key)}
            class="space-y-1 border-t border-white/6 bg-base/40 p-2"
          >
            <.track_row :for={track <- pl.tracks} track={track} />
          </ul>
        </div>

        <div :if={@singles != []}>
          <h2 class="mb-1.5 mt-4 text-caption font-semibold uppercase tracking-[0.14em] text-ink-faint">
            Avulsas
          </h2>
          <ul class="space-y-1">
            <.track_row :for={track <- @singles} track={track} />
          </ul>
        </div>
      </div>
    </.app_shell>
    """
  end

  attr :track, :map, required: true

  defp track_row(assigns) do
    ~H"""
    <li class="grid grid-cols-[44px_minmax(0,1fr)_auto] items-center gap-3 rounded-lg bg-surface px-3 py-2 hover:bg-surface-2">
      <.cover_play
        src={cover_src(@track)}
        artist={@track.tag_artist}
        size={40}
        play_src={~p"/audio/#{@track.id}"}
        track_id={@track.id}
        preview={true}
      />
      <div class="min-w-0">
        <div class="flex items-center gap-1.5">
          <.link
            navigate={~p"/track/#{@track.id}"}
            class="truncate text-body font-medium text-ink hover:text-primary hover:underline"
          >
            {track_title(@track)}
          </.link>
          <.ouro_badge track={@track} />
        </div>
        <p class="truncate text-caption text-ink-muted">
          {@track.tag_artist || "—"} · {(@track.raw_tags || %{})["youtube_title"]}
        </p>
        <p class="mt-0.5 flex items-center gap-2 text-[10px] text-ink-faint">
          <span>{format_views(@track.youtube_views)} views</span>
          <span>· {format_age(@track.youtube_published_at)}</span>
          <span :if={@track.genre_folder} class="text-green">· classificada</span>
          <span :if={@track.soundcharts_song_id} class="text-primary">· resolvida</span>
          <a
            :if={(@track.raw_tags || %{})["youtube_url"]}
            href={(@track.raw_tags || %{})["youtube_url"]}
            target="_blank"
            rel="noopener"
            aria-label={"Abrir o vídeo de #{track_title(@track)} no YouTube"}
            class="text-ink-muted hover:text-ink"
          >
            ↗ vídeo
          </a>
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-1.5">
        <button
          phx-click="toggle_gold"
          phx-value-id={@track.id}
          class="rounded-md px-2 py-1 text-[12px] text-ink-muted hover:text-[#f5c518]"
          aria-label={"Marcar/desmarcar Ouro em #{track_title(@track)}"}
          title="Marcar/desmarcar Ouro"
        >
          ★
        </button>
        <button
          phx-click="delete"
          phx-value-id={@track.id}
          data-confirm="Apagar este arquivo de vez? Isso não tem volta."
          class="rounded-md px-2 py-1 text-[12px] text-ink-muted hover:text-coral"
          aria-label={"Apagar de vez #{track_title(@track)}"}
          title="Apagar de vez"
        >
          Apagar
        </button>
      </div>
    </li>
    """
  end

  defp track_title(track), do: track.tag_title || track.filename

  defp chip_class(active?) do
    [
      "rounded-sm border px-[9px] py-[5px] text-[11px] font-semibold transition-colors",
      active? && "border-primary/60 bg-primary/20 text-ink",
      !active? && "border-white/8 bg-input text-ink-muted hover:border-white/20"
    ]
  end
end
