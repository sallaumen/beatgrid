defmodule BeatgridWeb.ImportsLive do
  @moduledoc "Triagem das faixas vindas do YouTube: ver views/idade, marcar Ouro, apagar lixo antes de gastar token."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library
  alias Beatgrid.Library.{TrackQuery, Tracks}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(filters: %{}, sort: :recent) |> load()}
  end

  defp load(socket) do
    filters = Map.put(socket.assigns.filters, :sort, socket.assigns.sort)
    assign(socket, tracks: TrackQuery.youtube_imports(filters))
  end

  @impl true
  def handle_event("toggle_filter", %{"key" => key}, socket) do
    k = String.to_existing_atom(key)
    filters = Map.update(socket.assigns.filters, k, true, fn v -> if v, do: nil, else: true end)
    {:noreply, socket |> assign(filters: filters) |> load()}
  end

  def handle_event("sort", %{"by" => by}, socket) do
    {:noreply, socket |> assign(sort: String.to_existing_atom(by)) |> load()}
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

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:importados} socket={@socket}>
      <div class="px-6 py-5">
        <header class="mb-4">
          <h1 class="text-h2 font-semibold">Importados do YouTube</h1>
          <p class="text-body-sm text-ink-muted">
            Triagem do que veio do YouTube — apague o que não presta antes de enriquecer.
          </p>
        </header>

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
          :if={@tracks == []}
          class="rounded-xl border border-white/6 bg-surface p-8 text-center text-ink-muted"
        >
          Nenhum importado do YouTube por aqui.
        </div>

        <ul class="space-y-1">
          <li
            :for={track <- @tracks}
            class="grid grid-cols-[44px_minmax(0,1fr)_auto] items-center gap-3 rounded-lg bg-surface px-3 py-2 hover:bg-surface-2"
          >
            <.cover_play
              src={cover_src(track)}
              artist={track.tag_artist}
              size={40}
              play_src={~p"/audio/#{track.id}"}
              track_id={track.id}
              preview={true}
            />
            <div class="min-w-0">
              <div class="flex items-center gap-1.5">
                <p class="truncate text-body font-medium">{track_title(track)}</p>
                <.ouro_badge track={track} />
              </div>
              <p class="truncate text-caption text-ink-muted">
                {track.tag_artist || "—"} · {(track.raw_tags || %{})["youtube_title"]}
              </p>
              <p class="mt-0.5 flex items-center gap-2 text-[10px] text-ink-faint">
                <span>{format_views(track.youtube_views)} views</span>
                <span>· {format_age(track.youtube_published_at)}</span>
                <span :if={track.genre_folder} class="text-green">· classificada</span>
                <span :if={track.soundcharts_song_id} class="text-primary">· resolvida</span>
                <a
                  :if={(track.raw_tags || %{})["youtube_url"]}
                  href={(track.raw_tags || %{})["youtube_url"]}
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
                phx-value-id={track.id}
                class="rounded-md px-2 py-1 text-[12px] text-ink-muted hover:text-[#f5c518]"
                title="Marcar/desmarcar Ouro"
              >
                ★
              </button>
              <button
                phx-click="delete"
                phx-value-id={track.id}
                data-confirm="Apagar este arquivo de vez? Isso não tem volta."
                class="rounded-md px-2 py-1 text-[12px] text-ink-muted hover:text-coral"
                title="Apagar de vez"
              >
                Apagar
              </button>
            </div>
          </li>
        </ul>
      </div>
    </.app_shell>
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
