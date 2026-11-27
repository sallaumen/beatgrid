defmodule BeatgridWeb.ImportsLive do
  @moduledoc "Reviews local and online imports and follows their background jobs."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.{Jobs, Library, Repertoire}
  alias Beatgrid.Library.{TrackQuery, Tracks}
  alias Beatgrid.Spotify.Playlist
  alias Beatgrid.YouTube
  alias Beatgrid.YouTube.{Playlists, Preview}
  alias BeatgridWeb.LocalImportComponent

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Library.subscribe_import()
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
       page_title: "Importações",
       online_route: ~p"/importados",
       local_progress_event: nil,
       filters: %{},
       sort: :recent,
       expanded: MapSet.new(),
       urls: "",
       rows: [],
       spotify: nil,
       spotify_filter: "all",
       spotify_index: nil,
       loading: false,
       error: nil,
       search: nil,
       recommendation: recommendation,
       selected: MapSet.new()
     )
     |> load()}
  end

  @impl true
  def handle_params(%{"origem" => "local"}, _uri, socket),
    do: {:noreply, assign(socket, mode: :local)}

  def handle_params(params, _uri, socket) do
    batch =
      case Ecto.UUID.cast(params["lote"]) do
        {:ok, id} -> id
        :error -> nil
      end

    online_route =
      case Map.take(params, ["lote", "recomendacao"]) do
        query when map_size(query) == 0 -> ~p"/importados"
        query -> ~p"/importados?#{query}"
      end

    {:noreply,
     socket |> assign(mode: :online, batch: batch, online_route: online_route) |> load_activity()}
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
    {:noreply, if(socket.assigns.mode == :online, do: load_activity(socket), else: socket)}
  end

  def handle_info({:import_progress, progress}, socket),
    do: {:noreply, assign(socket, local_progress_event: progress)}

  def handle_info({:tracks_moved, _result}, socket), do: {:noreply, socket}

  def handle_info({:youtube_tick}, %{assigns: %{mode: :local}} = socket),
    do: {:noreply, load(socket)}

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
     |> assign(
       urls: urls,
       rows: [],
       spotify: nil,
       selected: MapSet.new(),
       loading: false,
       error: nil,
       search: nil
     )}
  end

  def handle_event("preview_links", %{"urls" => input}, socket) do
    urls = String.trim(input)

    socket =
      assign(socket,
        urls: urls,
        search: nil,
        spotify: nil,
        spotify_filter: "all",
        spotify_index: nil,
        recommendation: nil
      )

    case Playlist.id(urls) do
      {:ok, id} ->
        {:noreply, start_review(socket, :spotify, fn -> Playlist.preview(id) end)}

      :invalid ->
        {:noreply, start_review(socket, :videos, fn -> Preview.list(urls) end)}
    end
  end

  def handle_event("find_version", %{"index" => index}, socket) do
    tracks = if socket.assigns.spotify, do: socket.assigns.spotify.tracks, else: []

    with true <- is_binary(index),
         {i, ""} when i >= 0 <- Integer.parse(index),
         %{artist: artist, title: title} <- Enum.at(tracks, i) do
      {:noreply,
       search_versions(
         assign(socket, recommendation: nil, spotify_index: i),
         artist <> " " <> title
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("filter_spotify", %{"filter" => filter}, socket)
      when filter in ~w(all missing library),
      do: {:noreply, assign(socket, spotify_filter: filter)}

  def handle_event("filter_spotify", _params, socket), do: {:noreply, socket}

  def handle_event("back_to_spotify", _, socket) do
    {:noreply,
     socket
     |> cancel_async(:preview)
     |> assign(search: nil, rows: [], selected: MapSet.new(), loading: false, error: nil)}
  end

  def handle_event("find_recommendation", _, %{assigns: %{recommendation: rec}} = socket)
      when not is_nil(rec) do
    {:noreply, search_versions(socket, rec.youtube_query || "#{rec.artist} #{rec.song}")}
  end

  def handle_event(
        "toggle_playlist_selection",
        _,
        %{assigns: %{rows: rows, selected: selected}} = socket
      ) do
    next =
      if MapSet.size(selected) == length(rows), do: MapSet.new(), else: MapSet.new(rows, & &1.id)

    {:noreply, assign(socket, selected: next)}
  end

  def handle_event("select_downloads", params, socket) do
    {:noreply,
     assign(socket,
       selected:
         MapSet.intersection(
           MapSet.new(socket.assigns.rows, & &1.id),
           MapSet.new(List.wrap(params["ids"]))
         )
     )}
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
           urls: if(socket.assigns.spotify, do: socket.assigns.urls, else: ""),
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
    selected =
      for row <- rows, kind == :videos, is_nil(row.playlist_url), into: MapSet.new(), do: row.id

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

  defp download_state_color("completed"), do: "text-green"
  defp download_state_color("executing"), do: "text-primary-soft"
  defp download_state_color(state) when state in ["retryable", "suspended"], do: "text-amber"
  defp download_state_color("discarded"), do: "text-coral-soft"
  defp download_state_color(_state), do: "text-ink-muted"

  defp toggle(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:importados} socket={@socket}>
      <div class="px-3 py-4 sm:px-6 sm:py-5">
        <h1 class="mb-3 text-[22px] font-semibold">Importações</h1>
        <nav
          id="import-sources"
          aria-label="Origem da importação"
          class="mb-4 flex flex-wrap gap-2 border-b border-white/8 pb-3"
        >
          <.link
            patch={@online_route}
            aria-current={@mode == :online && "page"}
            class={["inline-flex min-h-11 items-center sm:min-h-0", chip_class(@mode == :online)]}
          >
            <.icon name="hero-link" class="mr-1.5 size-4" /> YouTube e Spotify
          </.link>
          <.link
            patch={~p"/importados?origem=local"}
            aria-current={@mode == :local && "page"}
            class={["inline-flex min-h-11 items-center sm:min-h-0", chip_class(@mode == :local)]}
          >
            <.icon name="hero-folder" class="mr-1.5 size-4" /> Pasta ou arquivo
          </.link>
        </nav>

        <.live_component
          module={LocalImportComponent}
          id="local-import"
          active={@mode == :local}
          progress_event={@local_progress_event}
        />
        <.online_imports :if={@mode == :online} {assigns} />
      </div>
    </.app_shell>
    """
  end

  attr :tracks, :list, required: true
  attr :filter, :string, required: true
  attr :last_index, :integer, default: nil

  defp spotify_catalog(assigns) do
    tracks = Enum.with_index(assigns.tracks)
    in_library = Enum.count(tracks, fn {track, _} -> track.library_id end)

    visible =
      case assigns.filter do
        "missing" -> Enum.reject(tracks, fn {track, _} -> track.library_id end)
        "library" -> Enum.filter(tracks, fn {track, _} -> track.library_id end)
        "all" -> tracks
      end

    assigns =
      assign(assigns,
        visible: visible,
        counts: [
          {"all", "Todas", length(tracks)},
          {"missing", "Faltam", length(tracks) - in_library},
          {"library", "Na biblioteca", in_library}
        ]
      )

    ~H"""
    <section
      id="spotify-catalog"
      aria-label="Prévia da playlist do Spotify"
      class="mt-2 border-t border-white/10 pt-3"
    >
      <p class="text-body-sm text-ink-muted">Faixas da prévia pública do Spotify</p>
      <div
        id="spotify-filters"
        role="group"
        aria-label="Filtrar por presença na biblioteca"
        class="my-2 flex flex-wrap gap-1.5"
      >
        <button
          :for={{key, label, count} <- @counts}
          type="button"
          phx-click="filter_spotify"
          phx-value-filter={key}
          aria-pressed={to_string(@filter == key)}
          aria-controls="spotify-tracks"
          class={["inline-flex min-h-9 items-center gap-1.5", chip_class(@filter == key)]}
        >
          {label} <span class="font-mono tabular-nums">{count}</span>
        </button>
      </div>
      <ol
        id="spotify-tracks"
        class="max-h-96 overflow-y-auto"
        phx-mounted={if is_integer(@last_index), do: JS.focus(to: "#spotify-version-#{@last_index}")}
      >
        <li
          :for={{track, i} <- @visible}
          value={i + 1}
          class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-2 border-b border-white/6 py-2 sm:gap-x-3"
        >
          <span
            aria-hidden="true"
            class="min-w-5 text-right font-mono text-caption tabular-nums text-ink-faint"
          >{i + 1}</span>
          <div class="min-w-0">
            <p class="break-words text-body font-semibold">{track.title}</p>
            <p class="break-words text-body-sm text-ink-muted">{track.artist}</p>
            <.link
              :if={track.library_id}
              navigate={~p"/track/#{track.library_id}"}
              aria-label={"Abrir #{track.title} na biblioteca"}
              class="inline-block py-1 text-caption text-green hover:underline"
            >Abrir na biblioteca</.link>
          </div>
          <button
            id={"spotify-version-#{i}"}
            type="button"
            phx-click="find_version"
            phx-value-index={i}
            aria-label={"Buscar versões de #{track.title} no YouTube"}
            class="min-h-11 rounded-sm px-2 text-body-sm font-medium text-primary-soft hover:bg-input hover:underline"
          >Buscar versões</button>
        </li>
      </ol>
      <p :if={@visible == []} role="status" class="py-3 text-body-sm text-ink-muted">
        {case @filter do
          "library" -> "Nenhuma faixa desta prévia foi encontrada na biblioteca."
          "missing" -> "Todas as faixas desta prévia estão na biblioteca."
          _ -> "A prévia pública está vazia."
        end}
      </p>
    </section>
    """
  end

  defp online_imports(assigns) do
    ~H"""
    <div>
      <div class="mb-6 grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_360px]">
        <section
          class="min-w-0 rounded-lg border border-white/8 bg-surface p-4"
          aria-labelledby="online-import-title"
        >
          <h2 id="online-import-title" class="break-words text-[18px] font-semibold">
            {if @spotify, do: @spotify.title, else: "Importar de um link"}
          </h2>
          <details id="playlist-source" open={is_nil(@spotify)}>
            <summary
              hidden={is_nil(@spotify)}
              class="w-fit cursor-pointer py-2 text-body-sm text-primary-soft"
            >
              Alterar link da playlist
            </summary>
            <form id="link-preview" phx-submit="preview_links" phx-change="edit_links" class="mt-3">
              <label for="import-urls" class="block text-body font-semibold">Links do YouTube ou playlist do Spotify</label>
              <p id="link-hint" class="mb-2 text-body-sm text-ink-muted">
                Cole um link por linha. Para baixar uma playlist do YouTube, use o link da própria playlist.
              </p>
              <div class="flex flex-col items-end gap-2">
                <textarea
                  id="import-urls"
                  name="urls"
                  rows="3"
                  aria-describedby="link-hint"
                  placeholder="https://…"
                  class="w-full min-w-0 rounded-md border border-white/10 bg-input px-3 py-2 text-body"
                >{@urls}</textarea>
                <button
                  type="submit"
                  disabled={@loading}
                  class={[
                    "rounded-md px-4 py-2 text-body-sm font-semibold disabled:opacity-50",
                    if(is_nil(@spotify) && @rows == [],
                      do: "bg-primary-deep text-white",
                      else: "border border-white/10 bg-input text-ink-secondary hover:text-ink"
                    )
                  ]}
                >{if @loading, do: "Consultando…", else: "Conferir links"}</button>
              </div>
            </form>
          </details>

          <.spotify_catalog
            :if={@spotify && is_nil(@search)}
            tracks={@spotify.tracks}
            filter={@spotify_filter}
            last_index={@spotify_index}
          />
          <div
            :if={track = @spotify && @search && Enum.at(@spotify.tracks, @spotify_index)}
            id="spotify-versions"
            class="mt-3 border-t border-white/10 pt-3"
          >
            <button
              id="back-to-spotify"
              type="button"
              phx-click="back_to_spotify"
              class="inline-flex min-h-9 items-center gap-1.5 text-body-sm text-primary-soft hover:underline"
            >
              <.icon name="hero-arrow-left-mini" class="size-4" /> Voltar à playlist
            </button>
            <h3
              id="spotify-version-heading"
              tabindex="-1"
              phx-mounted={JS.focus()}
              class="mt-1 break-words text-body-lg font-semibold"
            >
              Versões de {track.title}
            </h3>
            <p class="text-body-sm text-ink-muted">
              {track.artist}
            </p>
          </div>
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
                {cond do
                  @spotify -> "Vídeos encontrados"
                  @search -> "Versões para “#{@search}”"
                  true -> "Confira as faixas"
                end}
              </legend>
              <p id="download-selection-count" role="status" class="mb-2 text-body-sm text-ink-muted">
                <span class="font-mono text-ink tabular-nums">{MapSet.size(@selected)}/{length(@rows)}</span>
                selecionadas
              </p>
              <button
                :if={length(@rows) > 1 && Enum.any?(@rows, & &1.playlist_url)}
                id="playlist-selection"
                type="button"
                phx-click="toggle_playlist_selection"
                class="mb-2 inline-flex min-h-9 items-center text-body-sm font-semibold text-primary-soft hover:underline"
              >{if MapSet.size(@selected) == length(@rows),
                do: "Limpar seleção",
                else: "Selecionar todas"}</button>
              <div class="max-h-72 overflow-y-auto">
                <div :for={row <- @rows} class="flex items-center gap-3 border-b border-white/6 py-1">
                  <label class="flex min-w-0 grow items-center gap-2 py-2 text-body-sm">
                    <input
                      type="checkbox"
                      name="ids[]"
                      class="shrink-0 accent-primary"
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
                    class="shrink-0 text-caption text-primary-soft underline"
                    aria-label={"Abrir #{row.title} no YouTube"}
                  >Ver vídeo</a>
                </div>
              </div>
            </fieldset>
            <button
              type="submit"
              disabled={MapSet.size(@selected) == 0}
              class="mt-3 rounded-sm bg-primary-deep px-4 py-2 text-body-sm font-semibold text-white disabled:opacity-50"
            >
              Baixar {MapSet.size(@selected)} {if MapSet.size(@selected) == 1,
                do: "faixa",
                else: "faixas"}
            </button>
          </form>
        </section>
        <section
          id="download-activity"
          class="min-w-0 rounded-lg border border-white/8 bg-surface p-4"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-[18px] font-semibold">
              {if @batch, do: "Lote de downloads", else: "Downloads recentes"}
            </h2>
            <.link
              navigate={~p"/jobs?worker=DownloadWorker"}
              class="text-body-sm text-primary-soft underline"
            >Ver fila e tentativas</.link>
          </div>
          <p :if={@downloads != []} class="mt-2 text-body-sm text-ink-muted" role="status">
            <span class="font-mono text-ink tabular-nums">{@completed}/{length(@downloads)}</span>
            concluídos
            <.link :if={@batch} patch={~p"/importados"} class="ml-2 text-primary-soft underline">Ver recentes</.link>
          </p>
          <p :if={@downloads == []} class="mt-2 text-body-sm text-ink-muted">
            Nenhum download recente.
          </p>
          <ul class="mt-2 max-h-40 overflow-y-auto xl:max-h-52">
            <li
              :for={job <- @downloads}
              class="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-x-3 border-b border-white/6 py-2 text-body-sm"
            >
              <span class="min-w-0 break-words">{job.args["title"] || job.args["video_id"] ||
                job.args["url"]}</span>
              <span class={["text-right text-caption", download_state_color(job.state)]}>{download_state(
                job.state
              )}</span>
              <span :if={issue = download_issue(job)} class="col-span-2 text-caption text-amber">{issue}</span>
            </li>
          </ul>
        </section>
      </div>
      <h2 class="mb-3 text-[18px] font-semibold">Faixas importadas do YouTube</h2>
      <div class="mb-3 flex flex-wrap items-center gap-1.5">
        <button
          phx-click="toggle_filter"
          phx-value-key="unfiled"
          aria-pressed={to_string(@filters[:unfiled] == true)}
          class={chip_class(@filters[:unfiled] == true)}
        >
          Não classificadas
        </button>
        <button
          phx-click="toggle_filter"
          phx-value-key="unresolved"
          aria-pressed={to_string(@filters[:unresolved] == true)}
          class={chip_class(@filters[:unresolved] == true)}
        >
          Não resolvidas
        </button>
        <button
          phx-click="toggle_filter"
          phx-value-key="gold"
          aria-pressed={to_string(@filters[:gold] == true)}
          class={chip_class(@filters[:gold] == true)}
        >
          ★ Ouro
        </button>
        <span class="ml-auto text-caption text-ink-faint">Ordenar:</span>
        <button
          phx-click="sort"
          phx-value-by="recent"
          aria-pressed={to_string(@sort == :recent)}
          class={chip_class(@sort == :recent)}
        >
          Recentes
        </button>
        <button
          phx-click="sort"
          phx-value-by="views"
          aria-pressed={to_string(@sort == :views)}
          class={chip_class(@sort == :views)}
        >
          Views
        </button>
        <button
          phx-click="sort"
          phx-value-by="published"
          aria-pressed={to_string(@sort == :published)}
          class={chip_class(@sort == :published)}
        >
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
            type="button"
            phx-click="toggle_playlist"
            phx-value-key={pl.key}
            aria-expanded={to_string(MapSet.member?(@expanded, pl.key))}
            class="flex min-w-0 flex-1 items-center gap-2 rounded-md py-1 text-left"
          >
            <.icon
              name={
                if MapSet.member?(@expanded, pl.key),
                  do: "hero-chevron-down",
                  else: "hero-chevron-right"
              }
              class="size-4 shrink-0 text-ink-muted"
            />
            <div class="min-w-0">
              <div class="break-words text-body font-semibold text-ink">{pl.title}</div>
              <div class="font-mono text-caption text-ink-muted tabular-nums">{pl.count} faixas</div>
            </div>
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
        <p class="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-caption text-ink-muted">
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
      <div class="flex shrink-0 flex-col items-end gap-1.5 sm:flex-row">
        <button
          phx-click="toggle_gold"
          phx-value-id={@track.id}
          class="rounded-md px-2 py-1 text-[12px] text-ink-muted hover:text-gold"
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
