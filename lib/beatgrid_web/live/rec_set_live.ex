defmodule BeatgridWeb.RecSetLive do
  @moduledoc "REC SET — build a harmonic set, auto-fill it, and export to M3U."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.{TrackQuery, Tracks}
  alias Beatgrid.Sets

  @impl true
  def mount(_params, _session, socket) do
    sets = Sets.list()

    {:ok,
     socket
     |> assign(page_title: "REC SET", toast: nil, seed_query: "")
     |> select(List.first(sets), sets)}
  end

  defp select(socket, nil, sets) do
    assign(socket, sets: sets, set: nil, tracks: [], candidates: [], seed_results: [])
  end

  defp select(socket, set, sets) do
    tracks = Sets.tracks(set)

    assign(socket,
      sets: sets,
      set: set,
      tracks: tracks,
      candidates: candidates(set, tracks),
      seed_results: []
    )
  end

  defp reload(socket), do: select(socket, Sets.get(socket.assigns.set.id), Sets.list())

  defp candidates(_set, []), do: []
  defp candidates(set, _tracks), do: Sets.next_candidates(set, limit: 8)

  @impl true
  def handle_event("new_set", _params, socket) do
    {:ok, set} = Sets.create("Novo set")
    {:noreply, select(socket, set, Sets.list())}
  end

  def handle_event("select_set", %{"id" => id}, socket) do
    {:noreply, select(socket, Sets.get(id), socket.assigns.sets)}
  end

  def handle_event("rename", %{"name" => name}, socket) do
    {:ok, set} = Sets.rename(socket.assigns.set, name)
    {:noreply, assign(socket, set: set, sets: Sets.list())}
  end

  def handle_event("delete_set", _params, socket) do
    {:ok, _} = Sets.delete(socket.assigns.set)
    sets = Sets.list()
    {:noreply, select(socket, List.first(sets), sets)}
  end

  def handle_event("append", %{"track" => track_id}, socket) do
    Sets.append(socket.assigns.set, Tracks.get(track_id))
    {:noreply, socket |> assign(seed_query: "") |> reload()}
  end

  def handle_event("remove", %{"track" => track_id}, socket) do
    Sets.remove(socket.assigns.set, Tracks.get(track_id))
    {:noreply, reload(socket)}
  end

  def handle_event("move", %{"track" => track_id, "dir" => dir}, socket) do
    Sets.move(socket.assigns.set, Tracks.get(track_id), String.to_existing_atom(dir))
    {:noreply, reload(socket)}
  end

  def handle_event("auto_fill", _params, socket) do
    {:ok, _} = Sets.auto_fill(socket.assigns.set, count: 8)
    {:noreply, reload(socket)}
  end

  def handle_event("search_seed", %{"q" => q}, socket) do
    results = if q == "", do: [], else: TrackQuery.library(%{search: q}) |> Enum.take(12)
    {:noreply, assign(socket, seed_query: q, seed_results: results)}
  end

  def handle_event("export", _params, socket) do
    toast =
      case Sets.export_m3u(socket.assigns.set) do
        {:ok, path} -> {:ok, Path.relative_to(path, Beatgrid.Library.library_root())}
        _ -> {:error, nil}
      end

    {:noreply, assign(socket, toast: toast)}
  end

  def handle_event("dismiss_toast", _params, socket), do: {:noreply, assign(socket, toast: nil)}

  # --- helpers ---

  defp total_time(tracks) do
    secs = tracks |> Enum.map(&(&1.duration_ms || 0)) |> Enum.sum() |> div(1000)
    "#{div(secs, 60)} min"
  end

  defp bpm(%{soundcharts_song: %{tempo_bpm: b}}) when is_number(b), do: round(b)
  defp bpm(_), do: "—"

  defp camelot(%{soundcharts_song: %{camelot: c}}), do: c
  defp camelot(_), do: nil

  defp title(t), do: t.tag_title || t.filename

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:sets}>
      <div class="flex h-screen">
        <aside class="flex w-60 shrink-0 flex-col border-r border-white/6 bg-rail">
          <div class="flex items-center justify-between px-4 py-3">
            <h2 class="text-[18px] font-semibold">Sets</h2>
            <button
              phx-click="new_set"
              class="rounded-md bg-primary px-2.5 py-1 text-[12px] font-semibold text-white"
            >
              + Novo
            </button>
          </div>
          <div class="min-h-0 flex-1 overflow-y-auto px-2 pb-3">
            <button
              :for={s <- @sets}
              phx-click="select_set"
              phx-value-id={s.id}
              class={[
                "block w-full truncate rounded-md px-2.5 py-2 text-left text-body-sm",
                @set && @set.id == s.id && "bg-primary/15 text-primary",
                !(@set && @set.id == s.id) && "text-ink-secondary hover:bg-white/5"
              ]}
            >
              {s.name}
            </button>
            <p :if={@sets == []} class="px-2.5 py-2 text-body-sm text-ink-faint">Nenhum set ainda.</p>
          </div>
        </aside>

        <section class="min-w-0 flex-1 overflow-y-auto">
          <.empty_state :if={is_nil(@set)} />
          <div :if={@set} class="mx-auto max-w-3xl px-6 py-5">
            <header class="flex items-center justify-between gap-3">
              <form id="set-name" phx-change="rename" class="flex-1">
                <input
                  name="name"
                  value={@set.name}
                  phx-debounce="500"
                  class="w-full bg-transparent text-[22px] font-semibold focus:outline-none"
                />
              </form>
              <div class="flex shrink-0 items-center gap-2">
                <button
                  :if={@tracks != []}
                  phx-click="auto_fill"
                  class="rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
                >
                  Completar automaticamente
                </button>
                <button
                  :if={@tracks != []}
                  phx-click="export"
                  class="rounded-md bg-primary px-3 py-1.5 text-body-sm font-semibold text-white"
                >
                  Exportar M3U
                </button>
                <button
                  phx-click="delete_set"
                  data-confirm="Excluir este set?"
                  class="rounded-md px-2 py-1.5 text-body-sm text-ink-muted hover:text-coral"
                >
                  Excluir
                </button>
              </div>
            </header>
            <p class="mt-1 text-caption text-ink-muted">
              {length(@tracks)} faixas · {total_time(@tracks)}
            </p>

            <.toast :if={@toast} toast={@toast} />

            <ol class="mt-4 space-y-1">
              <li
                :for={{t, i} <- Enum.with_index(@tracks, 1)}
                class="flex items-center gap-3 rounded-lg bg-surface px-2.5 py-2"
              >
                <span class="w-5 shrink-0 text-right font-mono text-[12px] text-ink-faint">{i}</span>
                <.cover artist={t.tag_artist} size={34} />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-body font-medium">{title(t)}</p>
                  <p class="truncate text-caption text-ink-muted">{t.tag_artist || "—"}</p>
                </div>
                <.camelot_seal value={camelot(t)} />
                <span class="w-10 text-right font-mono text-body text-primary">{bpm(t)}</span>
                <div class="flex shrink-0 items-center gap-1 text-[12px]">
                  <button
                    phx-click="move"
                    phx-value-track={t.id}
                    phx-value-dir="up"
                    class="text-ink-faint hover:text-ink"
                    title="Subir"
                  >
                    ▲
                  </button>
                  <button
                    phx-click="move"
                    phx-value-track={t.id}
                    phx-value-dir="down"
                    class="text-ink-faint hover:text-ink"
                    title="Descer"
                  >
                    ▼
                  </button>
                  <button
                    phx-click="remove"
                    phx-value-track={t.id}
                    class="ml-1 text-ink-muted hover:text-coral"
                    title="Remover"
                  >
                    ✕
                  </button>
                </div>
              </li>
            </ol>

            <.seed_picker :if={@tracks == []} query={@seed_query} results={@seed_results} />
            <.candidate_list :if={@tracks != []} candidates={@candidates} />
          </div>
        </section>
      </div>
    </.app_shell>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex h-full flex-col items-center justify-center gap-3 text-center">
      <span class="hero-queue-list size-10 text-ink-disabled" />
      <p class="text-ink-muted">Crie um set para começar a montar.</p>
      <button phx-click="new_set" class="text-body-sm text-primary hover:underline">+ Novo set</button>
    </div>
    """
  end

  attr :query, :string, required: true
  attr :results, :list, required: true

  defp seed_picker(assigns) do
    ~H"""
    <div class="mt-5">
      <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        Faixa-semente
      </p>
      <form id="seed-search" phx-change="search_seed">
        <input
          type="search"
          name="q"
          value={@query}
          phx-debounce="250"
          placeholder="Buscar a primeira faixa do set…"
          class="w-full rounded-md border border-white/8 bg-input px-3 py-2 text-body focus:border-primary/50 focus:outline-none"
        />
      </form>
      <div class="mt-2 space-y-1">
        <button
          :for={t <- @results}
          phx-click="append"
          phx-value-track={t.id}
          class="flex w-full items-center gap-3 rounded-lg px-2 py-1.5 text-left hover:bg-surface-2"
        >
          <.cover artist={t.tag_artist} size={30} />
          <div class="min-w-0 flex-1">
            <p class="truncate text-body-sm font-medium">{title(t)}</p>
            <p class="truncate text-caption text-ink-muted">{t.tag_artist || "—"}</p>
          </div>
          <.camelot_seal value={camelot(t)} />
        </button>
      </div>
    </div>
    """
  end

  attr :candidates, :list, required: true

  defp candidate_list(assigns) do
    ~H"""
    <div class="mt-5">
      <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        Próxima faixa ideal
      </p>
      <div :if={@candidates != []} class="space-y-1">
        <button
          :for={c <- @candidates}
          phx-click="append"
          phx-value-track={c.track.id}
          class="flex w-full items-center gap-3 rounded-lg border border-white/6 px-2.5 py-2 text-left hover:bg-surface-2"
        >
          <.cover artist={c.track.tag_artist} size={30} />
          <div class="min-w-0 flex-1">
            <p class="truncate text-body-sm font-medium">{title(c.track)}</p>
            <p class="truncate text-caption text-ink-muted">{c.track.tag_artist || "—"}</p>
          </div>
          <.camelot_seal value={c.camelot} />
          <span class="w-10 text-right font-mono text-body-sm text-primary">{round(c.bpm)}</span>
        </button>
      </div>
      <p :if={@candidates == []} class="text-body-sm text-ink-faint">
        Sem faixas compatíveis a partir da última (tom/BPM).
      </p>
    </div>
    """
  end

  attr :toast, :any, required: true

  defp toast(assigns) do
    ~H"""
    <div class="mt-4 flex items-center justify-between gap-4 rounded-lg border border-green/30 bg-green/10 px-4 py-2.5">
      <p class="text-body-sm text-ink">{toast_message(@toast)}</p>
      <button phx-click="dismiss_toast" class="text-ink-muted hover:text-ink text-body-sm">✕</button>
    </div>
    """
  end

  defp toast_message({:ok, rel}), do: "Set exportado para #{rel}"
  defp toast_message({:error, _}), do: "Falha ao exportar o set."
end
