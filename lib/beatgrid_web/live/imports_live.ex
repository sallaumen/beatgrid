defmodule BeatgridWeb.ImportsLive do
  @moduledoc "Triagem das faixas vindas do YouTube: agrupadas pela playlist de origem, com um atalho para virar set. Ver views/idade, marcar Ouro, apagar lixo antes de gastar token."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library
  alias Beatgrid.Library.{TrackQuery, Tracks}
  alias Beatgrid.YouTube
  alias Beatgrid.YouTube.Playlists

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(filters: %{}, sort: :recent, expanded: MapSet.new(), show_import: false)
     |> load()}
  end

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

  def handle_event("toggle_import", _params, socket) do
    {:noreply, update(socket, :show_import, &(not &1))}
  end

  def handle_event("import_playlist", %{"url" => url}, socket) do
    case YouTube.enqueue(url) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :error, "Cole um link do YouTube.")}

      {:ok, _n} ->
        {:noreply,
         socket
         |> assign(show_import: false)
         |> put_flash(
           :info,
           "Baixando do YouTube — as faixas aparecem conforme concluem (atualize em instantes)."
         )}
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

  defp toggle(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:importados} socket={@socket}>
      <div class="px-6 py-5">
        <header class="mb-4 flex items-start justify-between gap-3">
          <div>
            <h1 class="text-[22px] font-semibold">Importados do YouTube</h1>
            <p class="text-body-sm text-ink-muted">
              Agrupados pela playlist de origem — expanda para ver as faixas, ou crie um set direto.
            </p>
          </div>
          <button
            phx-click="toggle_import"
            class="shrink-0 rounded-md bg-primary-deep px-3.5 py-1.5 text-body-sm font-semibold text-white hover:bg-primary-deep/90"
          >
            + Importar playlist
          </button>
        </header>

        <div :if={@show_import} class="mb-4 rounded-xl border border-primary/30 bg-surface p-3">
          <form phx-submit="import_playlist" class="flex items-center gap-2">
            <input
              name="url"
              autocomplete="off"
              placeholder="Cole o link da playlist (ou vídeo) do YouTube"
              class="min-w-0 flex-1 rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm text-ink placeholder:text-ink-faint focus:border-primary/60 focus:outline-none"
            />
            <button
              type="submit"
              class="shrink-0 rounded-md bg-primary-deep px-3.5 py-1.5 text-body-sm font-semibold text-white hover:bg-primary-deep/90"
            >
              Baixar
            </button>
          </form>
          <p class="mt-1.5 text-caption text-ink-faint">
            Uma playlist vira um grupo aqui; um vídeo solto entra em “Avulsas”.
          </p>
        </div>

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
          title="Marcar/desmarcar Ouro"
        >
          ★
        </button>
        <button
          phx-click="delete"
          phx-value-id={@track.id}
          data-confirm="Apagar este arquivo de vez? Isso não tem volta."
          class="rounded-md px-2 py-1 text-[12px] text-ink-muted hover:text-coral"
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
