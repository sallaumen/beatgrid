defmodule BeatgridWeb.RecSetLive do
  @moduledoc "REC SET — build a scored set (style + harmony + energy arc), audition tracks, export M3U."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.{GenreFolders, TrackQuery, Tracks}
  alias Beatgrid.Mixing
  alias Beatgrid.Mixing.StyleAffinity
  alias Beatgrid.Sets

  @impl true
  def mount(_params, _session, socket) do
    sets = Sets.list()

    {:ok,
     socket
     |> assign(
       page_title: "REC SET",
       toast: nil,
       search_query: "",
       search_results: [],
       active_section: nil,
       folders: GenreFolders.list(),
       show_criteria: false
     )
     |> assign(sets: sets)
     |> load_set(List.first(sets))}
  end

  defp load_set(socket, nil), do: assign(socket, set: nil, entries: [], candidates: [])

  defp load_set(socket, set) do
    socket |> assign(set: set, entries: Sets.entries(set)) |> assign_candidates()
  end

  defp reload(socket), do: load_set(socket, Sets.get(socket.assigns.set.id))

  # Candidates reflect the active section's energy target, so changing the section
  # selector updates the preview below live. Automático (nil) = harmony + style only.
  defp assign_candidates(socket) do
    set = socket.assigns.set
    ti = section_target(socket.assigns[:active_section])

    candidates =
      cond do
        is_nil(set) -> []
        socket.assigns.entries == [] -> Sets.suggest_opening(set, limit: 8, target_intensity: ti)
        true -> Sets.next_candidates(set, limit: 8, target_intensity: ti)
      end

    assign(socket, candidates: candidates)
  end

  defp section_target(nil), do: nil
  defp section_target(role), do: Mixing.target_intensity(role)

  # --- set lifecycle ---

  @impl true
  def handle_event("new_set", _params, socket) do
    {:ok, set} = Sets.create("Novo set")
    {:noreply, socket |> assign(sets: Sets.list()) |> load_set(set)}
  end

  def handle_event("select_set", %{"id" => id}, socket) do
    {:noreply, socket |> assign(search_query: "", search_results: []) |> load_set(Sets.get(id))}
  end

  def handle_event("rename", %{"name" => name}, socket) do
    {:ok, set} = Sets.rename(socket.assigns.set, name)
    {:noreply, assign(socket, set: set, sets: Sets.list())}
  end

  def handle_event("set_target_style", %{"style" => style}, socket) do
    {:ok, set} = Sets.set_target_style(socket.assigns.set, blank_to_nil(style))
    {:noreply, load_set(socket, set)}
  end

  def handle_event("delete_set", _params, socket) do
    {:ok, _} = Sets.delete(socket.assigns.set)
    sets = Sets.list()
    {:noreply, socket |> assign(sets: sets) |> load_set(List.first(sets))}
  end

  # --- members ---

  def handle_event("append", %{"track" => track_id}, socket) do
    Sets.append(socket.assigns.set, Tracks.get(track_id))
    {:noreply, reload(socket)}
  end

  def handle_event("remove", %{"track" => track_id}, socket) do
    Sets.remove(socket.assigns.set, Tracks.get(track_id))
    {:noreply, reload(socket)}
  end

  def handle_event("move", %{"track" => track_id, "dir" => dir}, socket) do
    Sets.move(socket.assigns.set, Tracks.get(track_id), String.to_existing_atom(dir))
    {:noreply, reload(socket)}
  end

  # --- auto-composition ---

  def handle_event("set_section", %{"role" => role}, socket) do
    {:noreply, socket |> assign(active_section: blank_to_nil(role)) |> assign_candidates()}
  end

  def handle_event("fill", %{"role" => role, "count" => count}, socket) do
    n = to_count(count)

    case blank_to_nil(role) do
      nil -> Sets.auto_fill(socket.assigns.set, count: n)
      r -> Sets.fill_section(socket.assigns.set, r, n)
    end

    {:noreply, reload(socket)}
  end

  # --- search ---

  def handle_event("search", %{"q" => q}, socket) do
    results =
      if q == "" do
        []
      else
        members = MapSet.new(socket.assigns.entries, & &1.track.id)

        TrackQuery.library(%{search: q})
        |> Enum.reject(&MapSet.member?(members, &1.id))
        |> Enum.take(12)
      end

    {:noreply, assign(socket, search_query: q, search_results: results)}
  end

  # --- criteria modal ---

  def handle_event("show_criteria", _params, socket),
    do: {:noreply, assign(socket, show_criteria: true)}

  def handle_event("hide_criteria", _params, socket),
    do: {:noreply, assign(socket, show_criteria: false)}

  # --- export ---

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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp to_count(c) do
    case Integer.parse(to_string(c)) do
      {n, _} when n > 0 -> min(n, 20)
      _ -> 1
    end
  end

  defp total_time(entries) do
    secs = entries |> Enum.map(&(&1.track.duration_ms || 0)) |> Enum.sum() |> div(1000)
    "#{div(secs, 60)} min"
  end

  defp bpm(%{soundcharts_song: %{tempo_bpm: b}}) when is_number(b), do: round(b)
  defp bpm(%{bpm_detected: b}) when is_number(b), do: round(b)
  defp bpm(_), do: "—"

  defp camelot(%{soundcharts_song: %{camelot: c}}) when is_binary(c), do: c
  defp camelot(%{camelot_detected: c}) when is_binary(c), do: c
  defp camelot(_), do: nil

  defp title(t), do: t.tag_title || t.filename

  defp pct(v) when is_number(v), do: "#{round(v * 100)}%"
  defp pct(_), do: "—"
  defp short(name), do: String.slice(name || "", 0, 8)

  defp role_label(nil), do: nil
  defp role_label(role), do: with(%{label: l} <- Mixing.section(role), do: l)

  defp candidate_header(true, _section), do: "Sugestões de abertura"
  defp candidate_header(false, nil), do: "Próxima faixa ideal · Automático"
  defp candidate_header(false, label), do: "Próxima faixa ideal · #{label}"

  defp tier_symbol(:combina), do: "✅"
  defp tier_symbol(:cuidado), do: "⚠️"
  defp tier_symbol(:evitar), do: "❌"

  defp weight_label(:style), do: "Estilo"
  defp weight_label(:harmony), do: "Harmonia"
  defp weight_label(:intensity), do: "Intensidade"
  defp weight_label(:bpm), do: "BPM"
  defp weight_label(:rating), do: "Sua nota"

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:sets} socket={@socket}>
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
          <button
            phx-click="show_criteria"
            class="m-2 rounded-md border border-white/8 px-2.5 py-1.5 text-[12px] text-ink-muted hover:text-ink"
          >
            ⓘ Critérios de montagem
          </button>
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
                  phx-click="export"
                  disabled={@entries == []}
                  class="rounded-md bg-primary px-3 py-1.5 text-body-sm font-semibold text-white disabled:opacity-40"
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

            <div class="mt-2 flex flex-wrap items-center gap-3">
              <form id="target-style" phx-change="set_target_style">
                <label class="flex items-center gap-2 text-caption text-ink-muted">
                  Estilo-alvo
                  <select
                    name="style"
                    class="rounded-md border border-white/8 bg-input px-2 py-1 text-body-sm focus:border-primary/50 focus:outline-none"
                  >
                    <option value="" selected={is_nil(@set.target_style)}>— qualquer —</option>
                    <option
                      :for={f <- @folders}
                      value={f.key}
                      selected={f.key == @set.target_style}
                    >
                      {f.display_name}
                    </option>
                  </select>
                </label>
              </form>
              <span class="text-caption text-ink-faint">
                {length(@entries)} faixas · {total_time(@entries)}
              </span>
            </div>

            <.toast :if={@toast} toast={@toast} />

            <ol class="mt-4 space-y-1">
              <li
                :for={{e, i} <- Enum.with_index(@entries, 1)}
                class="flex items-center gap-3 rounded-lg bg-surface px-2.5 py-2"
              >
                <span class="w-5 shrink-0 text-right font-mono text-[12px] text-ink-faint">{i}</span>
                <.play_button
                  src={~p"/audio/#{e.track.id}"}
                  track_id={e.track.id}
                  preview={true}
                  size={28}
                />
                <.cover src={cover_src(e.track)} artist={e.track.tag_artist} size={34} />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-body font-medium">{title(e.track)}</p>
                  <p class="truncate text-caption text-ink-muted">{e.track.tag_artist || "—"}</p>
                </div>
                <span
                  :if={role_label(e.role)}
                  class="shrink-0 rounded-full bg-primary/15 px-2 py-px text-[10px] font-semibold text-primary"
                >
                  {role_label(e.role)}
                </span>
                <.camelot_seal value={camelot(e.track)} />
                <span class="w-10 text-right font-mono text-body text-primary">{bpm(e.track)}</span>
                <div class="flex shrink-0 items-center gap-1 text-[12px]">
                  <button
                    phx-click="move"
                    phx-value-track={e.track.id}
                    phx-value-dir="up"
                    class="text-ink-faint hover:text-ink"
                    title="Subir"
                  >▲</button>
                  <button
                    phx-click="move"
                    phx-value-track={e.track.id}
                    phx-value-dir="down"
                    class="text-ink-faint hover:text-ink"
                    title="Descer"
                  >▼</button>
                  <button
                    phx-click="remove"
                    phx-value-track={e.track.id}
                    class="ml-1 text-ink-muted hover:text-coral"
                    title="Remover"
                  >✕</button>
                </div>
              </li>
            </ol>

            <.section_fill active={@active_section} />
            <.candidate_list
              :if={@entries != []}
              candidates={@candidates}
              empty?={false}
              section={role_label(@active_section)}
            />
            <.candidate_list :if={@entries == []} candidates={@candidates} empty?={true} />
            <.search_box query={@search_query} results={@search_results} />
          </div>
        </section>
      </div>

      <.criteria_modal :if={@show_criteria} folders={@folders} />
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

  attr :active, :string, default: nil

  defp section_fill(assigns) do
    ~H"""
    <form
      id="section-fill"
      phx-change="set_section"
      phx-submit="fill"
      class="mt-5 flex flex-wrap items-end gap-2"
    >
      <label class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        Preencher
      </label>
      <select
        name="role"
        class="rounded-md border border-white/8 bg-input px-2 py-1.5 text-body-sm focus:border-primary/50 focus:outline-none"
      >
        <option value="" selected={is_nil(@active)}>Automático (harmonia + estilo)</option>
        <option :for={s <- Mixing.sections()} value={s.key} selected={s.key == @active}>
          {s.label}
        </option>
      </select>
      <input
        type="number"
        name="count"
        value="4"
        min="1"
        max="20"
        class="w-16 rounded-md border border-white/8 bg-input px-2 py-1.5 text-body-sm focus:border-primary/50 focus:outline-none"
      />
      <button class="rounded-md bg-primary px-3 py-1.5 text-body-sm font-semibold text-white">
        Preencher
      </button>
      <span class="text-caption text-ink-faint">
        adiciona N faixas; a seção define a intensidade-alvo (e o preview abaixo)
      </span>
    </form>
    """
  end

  attr :candidates, :list, required: true
  attr :empty?, :boolean, required: true
  attr :section, :string, default: nil

  defp candidate_list(assigns) do
    assigns = assign(assigns, :header, candidate_header(assigns.empty?, assigns.section))

    ~H"""
    <div class="mt-5">
      <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        {@header}
      </p>
      <div :if={@candidates != []} class="space-y-1">
        <div
          :for={c <- @candidates}
          class="flex items-center gap-3 rounded-lg border border-white/6 px-2.5 py-2"
        >
          <.play_button src={~p"/audio/#{c.track.id}"} track_id={c.track.id} preview={true} size={28} />
          <.cover src={cover_src(c.track)} artist={c.track.tag_artist} size={30} />
          <div class="min-w-0 flex-1">
            <p class="truncate text-body-sm font-medium">{title(c.track)}</p>
            <p class="truncate text-caption text-ink-muted">{c.track.tag_artist || "—"}</p>
            <div class="mt-0.5 flex flex-wrap gap-1.5 text-[10px] text-ink-faint">
              <span class="rounded bg-white/5 px-1.5 py-px">estilo {pct(c.breakdown.style)}</span>
              <span class="rounded bg-white/5 px-1.5 py-px">tom {pct(c.breakdown.harmony)}</span>
              <span class="rounded bg-white/5 px-1.5 py-px">intens. {pct(c.breakdown.intensity)}</span>
            </div>
          </div>
          <.camelot_seal value={c.camelot} />
          <span class="w-10 text-right font-mono text-body-sm text-primary">{round(c.bpm || 0)}</span>
          <button
            phx-click="append"
            phx-value-track={c.track.id}
            class="shrink-0 rounded-md bg-primary/15 px-2.5 py-1 text-[12px] font-semibold text-primary hover:bg-primary/25"
          >
            + Add
          </button>
        </div>
      </div>
      <p :if={@candidates == []} class="text-body-sm text-ink-faint">
        Sem candidatos — comece pela busca abaixo.
      </p>
    </div>
    """
  end

  attr :query, :string, required: true
  attr :results, :list, required: true

  defp search_box(assigns) do
    ~H"""
    <div class="mt-5">
      <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
        Buscar e adicionar
      </p>
      <form id="track-search" phx-change="search">
        <input
          type="search"
          name="q"
          value={@query}
          phx-debounce="250"
          placeholder="Buscar faixa por título ou artista…"
          class="w-full rounded-md border border-white/8 bg-input px-3 py-2 text-body focus:border-primary/50 focus:outline-none"
        />
      </form>
      <div :if={@results != []} id="search-results" class="mt-2 space-y-1">
        <div
          :for={t <- @results}
          class="flex items-center gap-3 rounded-lg px-2 py-1.5 hover:bg-surface-2"
        >
          <.play_button src={~p"/audio/#{t.id}"} track_id={t.id} preview={true} size={28} />
          <.cover src={cover_src(t)} artist={t.tag_artist} size={30} />
          <div class="min-w-0 flex-1">
            <p class="truncate text-body-sm font-medium">{title(t)}</p>
            <p class="truncate text-caption text-ink-muted">{t.tag_artist || "—"}</p>
          </div>
          <.camelot_seal value={camelot(t)} />
          <button
            phx-click="append"
            phx-value-track={t.id}
            class="shrink-0 rounded-md bg-primary/15 px-2.5 py-1 text-[12px] font-semibold text-primary hover:bg-primary/25"
          >
            + Add
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :folders, :list, required: true

  defp criteria_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-20 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/60" phx-click="hide_criteria"></div>
      <div class="relative max-h-[85vh] w-full max-w-2xl overflow-y-auto rounded-xl border border-white/10 bg-surface p-5">
        <div class="mb-4 flex items-center justify-between">
          <h3 class="text-[18px] font-semibold">Critérios de montagem</h3>
          <button phx-click="hide_criteria" class="text-ink-muted hover:text-ink">✕</button>
        </div>
        <p class="mb-4 text-caption text-ink-muted">
          Estes valores vêm do backend — o algoritmo e esta tela usam a mesma fonte.
        </p>

        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Pesos</p>
        <div class="mb-4 grid grid-cols-2 gap-1.5 sm:grid-cols-5">
          <div
            :for={{k, v} <- Enum.sort_by(Map.to_list(Mixing.weights()), fn {_k, v} -> -v end)}
            class="rounded-lg bg-base px-2.5 py-2 text-center"
          >
            <p class="font-mono text-[18px] font-semibold text-primary">{v}</p>
            <p class="text-caption text-ink-muted">{weight_label(k)}</p>
          </div>
        </div>

        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
          Seções (arco de energia)
        </p>
        <div class="mb-4 space-y-1">
          <div
            :for={s <- Mixing.sections()}
            class="flex items-center gap-3 rounded-lg bg-base px-2.5 py-1.5"
          >
            <span class="w-20 font-semibold text-primary">{s.label}</span>
            <div class="h-[6px] flex-1 rounded-full bg-white/5">
              <div
                class="h-full rounded-full bg-green"
                style={"width:#{round(s.target_intensity * 100)}%"}
              >
              </div>
            </div>
            <span class="w-10 text-right font-mono text-caption text-ink-muted">
              {round(s.target_intensity * 100)}
            </span>
            <span class="hidden text-caption text-ink-faint sm:inline">{s.hint}</span>
          </div>
        </div>

        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
          Afinidade de estilos
        </p>
        <div class="overflow-x-auto">
          <table class="min-w-full border-collapse text-[11px]">
            <thead>
              <tr>
                <th class="p-1"></th>
                <th :for={c <- @folders} class="p-1 text-ink-faint">{short(c.display_name)}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- @folders}>
                <td class="whitespace-nowrap p-1 text-right text-ink-muted">{r.display_name}</td>
                <td
                  :for={c <- @folders}
                  class="p-1 text-center"
                  title={"#{r.display_name} × #{c.display_name}"}
                >
                  {tier_symbol(StyleAffinity.tier(r.key, c.key))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="mt-2 text-caption text-ink-faint">✅ combina · ⚠️ com cuidado · ❌ evitar</p>
      </div>
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
