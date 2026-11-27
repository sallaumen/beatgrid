defmodule BeatgridWeb.JobsLive do
  @moduledoc """
  Background-jobs visibility: a live list of recent Oban jobs across all queues,
  with their state, queue, a human-readable summary of what each job is doing,
  attempts, timing, the last error, and retry/cancel actions.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Jobs
  alias Beatgrid.Library.Tracks

  @refresh_ms 2_000
  @active_states ~w(available scheduled executing retryable suspended)
  @failed_states ~w(discarded cancelled)
  @states @active_states ++ @failed_states ++ ["completed"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, assign(socket, page_title: "Fila de tarefas", expanded: MapSet.new())}
  end

  # URL-driven filters (`?state=failed&worker=DownloadWorker`) so callers can
  # deep-link straight to "the downloads that gave up" and the view survives
  # refresh/back. "active" covers unfinished work; "failed" covers discarded + cancelled.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = valid_state(params["state"])
    worker = valid_worker(params["worker"])

    {:noreply,
     socket
     |> assign(filter: filter, group: state_group(filter), worker: worker)
     |> assign(context_link: worker_destination(worker))
     |> assign_jobs()}
  end

  defp valid_state(state) when state in @states or state in ["active", "failed"], do: state
  defp valid_state(_state), do: nil

  defp valid_worker(worker) when is_binary(worker) do
    if Regex.match?(~r/^[A-Za-z]+$/, worker), do: worker
  end

  defp valid_worker(_worker), do: nil

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_jobs(socket)}
  end

  @impl true
  def handle_event("filter_worker", %{"worker" => name}, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket.assigns.filter, valid_worker(name)))}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    Jobs.retry(String.to_integer(id))

    {:noreply,
     socket
     |> put_flash(:info, "Pedido de nova tentativa enviado. Acompanhe em andamento.")
     |> assign_jobs()}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    Jobs.cancel(String.to_integer(id))

    {:noreply,
     socket
     |> put_flash(:info, "Pedido de cancelamento enviado. Confira o estado em Todas.")
     |> assign_jobs()}
  end

  def handle_event("retry_all_failed", _params, socket) do
    count = Jobs.retry_failed(socket.assigns.worker)

    {:noreply,
     socket |> put_flash(:info, "Tarefas recolocadas na fila: #{count}.") |> assign_jobs()}
  end

  def handle_event("clear_all_failed", _params, socket) do
    count = Jobs.clear_failed(socket.assigns.worker)
    {:noreply, socket |> put_flash(:info, "#{count} falha(s) limpa(s).") |> assign_jobs()}
  end

  def handle_event("toggle_details", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, expanded: expanded)}
  end

  defp assign_jobs(socket) do
    jobs = load(socket.assigns.filter, socket.assigns.worker)
    assign(socket, jobs: jobs, titles: track_titles(jobs))
  end

  defp load(filter, worker),
    do: Jobs.list_recent(limit: 100, states: filter_states(filter), worker: worker)

  defp filter_states(nil), do: nil
  defp filter_states("active"), do: @active_states
  defp filter_states("failed"), do: @failed_states
  defp filter_states(state), do: [state]

  defp active_state?(state), do: state in @active_states
  defp retryable_state?(state), do: state == "retryable" or state in @failed_states

  defp state_group(state) when state in @active_states, do: "active"
  defp state_group(state) when state in @failed_states, do: "failed"
  defp state_group(state), do: state

  defp group_phases("active"), do: @active_states
  defp group_phases("failed"), do: @failed_states
  defp group_phases(_), do: []

  defp worker_destination(worker) when worker in ~w(DownloadWorker ExpandWorker),
    do: {~p"/importados", "Importações"}

  defp worker_destination("ImportWorker"), do: {~p"/importados?origem=local", "Arquivos locais"}

  defp worker_destination(worker)
       when worker in ~w(MixDownloadWorker MixAnalyzeWorker MixDjAudioWorker MixDjVisionWorker MixRecognizeWorker MixCutWorker),
       do: {~p"/sets-online", "Sets gravados"}

  defp worker_destination(worker)
       when worker in ~w(AnalyzeWorker MarkerAnalyzeWorker LoudnessWorker GainApplyWorker DbBackupWorker EnrichWorker),
       do: {~p"/manutencao", "Manutenção"}

  defp worker_destination(_), do: nil

  # Resolve the track titles referenced by the visible jobs in one batched query,
  # so the summary reads "Asa Branca" instead of a bare UUID.
  defp track_titles(jobs) do
    case jobs |> Enum.flat_map(&job_track_ids/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        Tracks.list_by(ids: ids)
        |> Map.new(fn t -> {t.id, t.tag_title || t.filename} end)
    end
  end

  # Workers whose args carry a plain track id under this key; the scoped workers
  # (Enrich/Recommend) only reference a track when their scope says so.
  @track_id_arg %{
    "AnalyzeWorker" => "track_id",
    "ResolveSongWorker" => "track_id",
    "GainApplyWorker" => "track_id",
    "LoudnessWorker" => "track_id",
    "MarkerAnalyzeWorker" => "track_id"
  }

  defp job_track_ids(%Oban.Job{worker: worker, args: args}) do
    case worker_name(worker) do
      "EnrichWorker" -> scoped_track_id(args, "id")
      "RecommendWorker" -> scoped_track_id(args, "track_id")
      name -> args |> Map.get(@track_id_arg[name] || "") |> List.wrap()
    end
  end

  defp scoped_track_id(%{"scope" => "track"} = args, key), do: List.wrap(args[key])
  defp scoped_track_id(_args, _key), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:jobs} socket={@socket}>
      <header class="border-b border-white/6 bg-rail px-3 py-3 sm:px-6">
        <div class="mx-auto max-w-[1600px]">
          <h1 class="text-title font-semibold">Fila de tarefas</h1>
          <p class="text-body-sm text-ink-muted">
            Acompanhe tarefas em segundo plano e tente novamente as que falharam.
          </p>
        </div>
      </header>
      <div class="mx-auto max-w-[1600px] px-3 py-5 sm:px-6">
        <div class="grid gap-3 border-b border-white/8 pb-3 lg:grid-cols-[minmax(0,1fr)_14rem] lg:items-start">
          <div class="min-w-0 space-y-1">
            <p id="job-state-label" class="text-body-sm font-semibold text-ink-secondary">
              Estado da tarefa
            </p>
            <nav
              id="job-state-groups"
              aria-labelledby="job-state-label"
              class="flex flex-wrap items-center gap-1.5"
            >
              <.link
                :for={
                  {state, label} <-
                    [
                      {"active", "Em andamento"},
                      {"failed", "Falhas"},
                      {"completed", "Concluídas"},
                      {nil, "Todas"}
                    ]
                }
                patch={jobs_path(state, @worker)}
                aria-current={@filter == state && "true"}
                class={["rounded-md border px-2.5 py-1.5 text-body", chip_class(@group == state)]}
              >
                {label}
              </.link>
            </nav>
            <nav
              :if={group_phases(@group) != []}
              id="job-state-phases"
              aria-label="Filtrar por etapa"
              class="flex flex-wrap items-center gap-1.5 pt-1"
            >
              <span class="text-body-sm text-ink-muted">Etapa:</span>
              <.link
                :for={state <- group_phases(@group)}
                patch={jobs_path(state, @worker)}
                aria-current={@filter == state && "true"}
                class={["rounded-md border px-2 py-1 text-body-sm", chip_class(@filter == state)]}
              >
                {state_label(state)}
              </.link>
            </nav>
          </div>

          <form
            id="task-type"
            phx-change="filter_worker"
            class="min-w-0"
          >
            <label
              for="worker-filter"
              class="mb-1 block text-body-sm font-semibold text-ink-secondary"
            >Tipo de tarefa</label>
            <select
              id="worker-filter"
              name="worker"
              class="w-full rounded-md border border-white/10 bg-input px-3 py-1.5 text-body"
            >
              <option value="">Todos os tipos</option>
              <option
                :for={{name, label} <- worker_options(@worker)}
                value={name}
                selected={name == @worker}
              >
                {label}
              </option>
            </select>
            <.link
              :if={@context_link}
              id="jobs-context-link"
              navigate={elem(@context_link, 0)}
              class="mt-1.5 inline-flex items-center gap-1 text-body-sm text-primary hover:underline"
            >
              Abrir {elem(@context_link, 1)} <.icon name="hero-arrow-right-mini" class="size-4" />
            </.link>
          </form>
        </div>

        <div
          :if={@filter == "failed" and @jobs != []}
          class="mt-3 flex flex-wrap items-start justify-between gap-3 border-b border-white/8 pb-3"
        >
          <div>
            <p class="text-body font-semibold">
              Ações em lote · {if @worker, do: worker_label(@worker), else: "Todos os tipos"}
            </p>
            <p class="mt-0.5 text-body-sm text-ink-muted">
              Incluem tarefas descartadas e canceladas, mesmo fora desta lista.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              phx-click="retry_all_failed"
              data-confirm="Recolocar na fila todas as tarefas descartadas e canceladas deste filtro?"
              class="rounded-md border border-primary/30 bg-primary/10 px-3 py-1.5 text-body-sm font-semibold text-primary hover:bg-primary/15"
            >
              Tentar todas novamente
            </button>
            <button
              phx-click="clear_all_failed"
              data-confirm="Limpar do histórico todas as falhas deste filtro, inclusive as que estão fora desta página?"
              class="rounded-md border border-coral/25 bg-coral/10 px-3 py-1.5 text-body-sm font-medium text-coral hover:bg-coral/15"
            >
              Limpar histórico de falhas
            </button>
          </div>
        </div>

        <div class="mt-4 flex flex-wrap items-baseline justify-between gap-2">
          <h2 class="text-heading font-semibold">{results_heading(@filter)}</h2>
          <p class="text-body-sm text-ink-muted">
            <span class="font-mono tabular-nums text-ink-secondary">{length(@jobs)}</span>
            {if length(@jobs) == 100, do: "mais recentes", else: "exibidas"}
          </p>
        </div>

        <ul
          :if={@jobs != []}
          id="jobs-list"
          role="list"
          class="mt-2 divide-y divide-white/8 border-y border-white/8"
        >
          <li :for={j <- @jobs} id={"job-#{j.id}"} class="space-y-2 py-2.5">
            <div class="grid grid-cols-1 gap-2 sm:grid-cols-[minmax(0,1fr)_minmax(9rem,auto)] lg:grid-cols-[minmax(0,1fr)_14rem_12rem] lg:items-start lg:gap-4">
              <div class="min-w-0">
                <div class="flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
                  <p class="min-w-0 break-words text-body-lg font-semibold text-ink">
                    {worker_label(j.worker)}
                  </p>
                  <p class="min-w-0 break-words text-body text-ink-secondary">
                    {job_summary(j, @titles)}
                  </p>
                </div>
                <p :if={last_error(j)} class="mt-1 break-words text-body-sm text-coral">
                  {last_error(j)}
                </p>
                <p class="mt-1 break-words text-caption text-ink-muted">
                  <span class="font-mono">{worker_name(j.worker)}</span>
                  <span aria-hidden="true"> · </span> Fila <span class="font-mono">{j.queue}</span>
                </p>
              </div>

              <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1 sm:flex-col sm:items-start lg:flex-row lg:items-baseline">
                <span class={[
                  "rounded-xs px-2 py-0.5 text-caption font-semibold",
                  state_class(j.state)
                ]}>
                  {state_label(j.state)}
                </span>
                <span class="text-body-sm text-ink-secondary">{ago(job_time(j))}</span>
                <span class="text-body-sm text-ink-muted">
                  Tentativa <span class="font-mono tabular-nums">{j.attempt}/{j.max_attempts}</span>
                </span>
              </div>

              <div
                :if={j.errors != [] or active_state?(j.state) or retryable_state?(j.state)}
                class="flex flex-wrap items-start gap-1.5 sm:col-span-2 lg:col-span-1 lg:justify-end"
              >
                <button
                  :if={j.errors != []}
                  type="button"
                  phx-click="toggle_details"
                  phx-value-id={j.id}
                  aria-expanded={to_string(MapSet.member?(@expanded, j.id))}
                  class="rounded-md border border-white/10 px-2.5 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
                >
                  {if MapSet.member?(@expanded, j.id), do: "Ocultar", else: "Detalhes"}
                </button>
                <button
                  :if={retryable_state?(j.state)}
                  phx-click="retry"
                  phx-value-id={j.id}
                  class="rounded-md border border-primary/30 bg-primary/10 px-2.5 py-1.5 text-body-sm font-semibold text-primary hover:bg-primary/15"
                >
                  Tentar novamente
                </button>
                <button
                  :if={active_state?(j.state)}
                  phx-click="cancel"
                  phx-value-id={j.id}
                  data-confirm="Cancelar esta tarefa? Se já estiver executando, pode haver alterações parciais. Cancelar não desfaz o que já foi realizado."
                  class="rounded-md border border-coral/25 bg-coral/10 px-2.5 py-1.5 text-body-sm text-coral hover:bg-coral/15"
                >
                  Cancelar
                </button>
              </div>
            </div>

            <div
              :if={MapSet.member?(@expanded, j.id)}
              class="space-y-1 rounded-md bg-surface px-3 py-2"
            >
              <p class="break-all font-mono text-body-sm text-ink-muted">{full_url(j)}</p>
              <p
                :for={line <- all_errors(j)}
                class="break-all whitespace-pre-wrap font-mono text-body-sm text-coral"
              >
                {line}
              </p>
            </div>
          </li>
        </ul>
        <div
          :if={@jobs == []}
          class="mt-2 space-y-1 border-t border-white/8 py-4 text-body text-ink-muted"
        >
          <p>{empty_message(@filter)}</p>
          <.link
            :if={@filter || @worker}
            patch={jobs_path(nil, nil)}
            class="inline-block text-primary hover:underline"
          >Ver todas as tarefas</.link>
        </div>
      </div>
    </.app_shell>
    """
  end

  defp results_heading("active"), do: "Tarefas em andamento"
  defp results_heading("failed"), do: "Falhas e cancelamentos"
  defp results_heading("completed"), do: "Tarefas concluídas"
  defp results_heading(_), do: "Atividade recente"

  defp empty_message("active"), do: "Nenhuma tarefa em andamento neste filtro."
  defp empty_message("failed"), do: "Nenhuma tarefa descartada ou cancelada neste filtro."
  defp empty_message(_), do: "Nenhuma tarefa neste filtro."

  # ── Worker name + label ────────────────────────────────────────────────────

  defp worker_name(worker), do: worker |> String.split(".") |> List.last()

  defp jobs_path(state, worker) do
    case Enum.reject([state: state, worker: worker], fn {_key, value} -> is_nil(value) end) do
      [] -> ~p"/jobs"
      params -> ~p"/jobs?#{params}"
    end
  end

  # Friendly PT-BR action labels per worker; falls back to the bare module segment
  # so a newly-added worker still renders something readable. The real module name
  # is always shown alongside as a small tag, so this is the "what it does", not a
  # replacement for the technical name.
  @worker_labels %{
    "AnalyzeWorker" => "Analisar áudio",
    "DbBackupWorker" => "Salvar backup da biblioteca",
    "IntegrityCheckWorker" => "Verificar arquivos de áudio",
    "MixCutWorker" => "Recortar faixa de set gravado",
    "MoveBatchWorker" => "Mover faixas selecionadas",
    "DownloadWorker" => "Baixar do YouTube",
    "ExpandWorker" => "Expandir playlist",
    "ImportWorker" => "Importar arquivos",
    "EnrichWorker" => "Enriquecer metadados",
    "ResolveSongWorker" => "Resolver no Soundcharts",
    "ReResolveWorker" => "Re-resolver match",
    "ReevaluateWorker" => "Re-avaliar com IA",
    "RecommendWorker" => "Sugerir repertório",
    "DedupWorker" => "Procurar duplicatas",
    "ScanWorker" => "Escanear biblioteca",
    "ReviewApplyWorker" => "Aplicar revisão no disco",
    "UndoBatchWorker" => "Desfazer lote",
    "GainApplyWorker" => "Aplicar ganho",
    "LoudnessWorker" => "Medir loudness",
    "MarkerAnalyzeWorker" => "Detectar marcadores",
    "MixAnalyzeWorker" => "Analisar set online",
    "MixDjAudioWorker" => "Reconhecer por áudio (set online)",
    "MixDjVisionWorker" => "Ler telão do set online",
    "MixDownloadWorker" => "Baixar set online",
    "MixRecognizeWorker" => "Reconhecer faixas do set online"
  }

  defp worker_options(selected) do
    labels =
      if selected,
        do: Map.put_new(@worker_labels, selected, selected),
        else: @worker_labels

    Enum.sort_by(labels, fn {_name, label} -> label end)
  end

  defp worker_label(worker) do
    name = worker_name(worker)
    Map.get(@worker_labels, name, name)
  end

  # ── Human-readable summary (per worker, from args — never a dump of arg keys) ─

  defp job_summary(%Oban.Job{worker: worker, args: args}, titles),
    do: summarize(worker_name(worker), args, titles)

  defp summarize("DownloadWorker", args, _titles), do: args["title"] || args["url"] || "—"

  defp summarize("ExpandWorker", args, _titles),
    do: args["url"] || args["playlist_url"] || "playlist"

  defp summarize(worker, args, titles) when is_map_key(@track_id_arg, worker),
    do: track_ref(args[@track_id_arg[worker]], titles)

  defp summarize("EnrichWorker", args, titles), do: enrich_summary(args, titles)
  defp summarize("ReResolveWorker", args, _titles), do: "sugestão ##{args["suggestion_id"]}"
  defp summarize("ReevaluateWorker", args, _titles), do: reeval_summary(args)
  defp summarize("RecommendWorker", args, titles), do: recommend_summary(args, titles)
  defp summarize("ImportWorker", args, _titles), do: import_summary(args)
  defp summarize("DedupWorker", _args, _titles), do: "biblioteca inteira"
  defp summarize("ScanWorker", _args, _titles), do: "varredura da biblioteca"

  defp summarize("ReviewApplyWorker", %{"ids" => ids}, _titles),
    do: "#{length(ids)} sugestões selecionadas"

  defp summarize("UndoBatchWorker", %{"batch_id" => bid}, _titles),
    do: "lote ##{String.slice(to_string(bid), 0, 8)}"

  defp summarize(_worker, args, _titles), do: generic_summary(args)

  defp track_ref(nil, _titles), do: "—"

  defp track_ref(id, titles),
    do: Map.get(titles, id, "faixa ##{String.slice(to_string(id), 0, 8)}")

  defp enrich_summary(%{"scope" => "pending"}, _titles), do: "todas as pendentes · Soundcharts"
  defp enrich_summary(%{"scope" => "rare"}, _titles), do: "faixas raras · IA e análise local"

  defp enrich_summary(%{"scope" => "track", "id" => id}, titles),
    do: "#{track_ref(id, titles)} · Soundcharts"

  defp enrich_summary(_, _titles), do: "Soundcharts"

  defp reeval_summary(%{"scope" => "folder", "folder" => key}), do: "pasta: #{folder_label(key)}"
  defp reeval_summary(%{"scope" => "one", "id" => id}), do: "sugestão ##{id}"
  defp reeval_summary(%{"scope" => scope}), do: "escopo: #{reeval_scope(scope)}"
  defp reeval_summary(_), do: "—"

  defp reeval_scope("unevaluated"), do: "ainda não avaliadas"
  defp reeval_scope("pending"), do: "pendentes"
  defp reeval_scope("rejected"), do: "rejeitadas"
  defp reeval_scope(other), do: to_string(other)

  defp recommend_summary(%{"scope" => "folder", "folder" => key}, _titles),
    do: "pasta: #{folder_label(key)}"

  defp recommend_summary(%{"scope" => "track", "track_id" => id}, titles),
    do: track_ref(id, titles)

  defp recommend_summary(_, _titles), do: "repertório"

  defp import_summary(%{"items" => items}) when is_list(items), do: "#{length(items)} arquivo(s)"
  defp import_summary(_), do: "arquivos"

  defp generic_summary(args) do
    case args |> Map.drop(["batch_id"]) |> Map.values() |> Enum.filter(&is_binary/1) do
      [] -> "—"
      vals -> Enum.join(vals, " · ")
    end
  end

  # ── Timing ─────────────────────────────────────────────────────────────────

  defp job_time(%Oban.Job{state: state, scheduled_at: at})
       when state in ["scheduled", "retryable"], do: at

  defp job_time(%Oban.Job{} = j) do
    j.completed_at || j.cancelled_at || j.discarded_at || j.attempted_at || j.scheduled_at ||
      j.inserted_at
  end

  defp ago(nil), do: "—"

  defp ago(%NaiveDateTime{} = ndt), do: ago(DateTime.from_naive!(ndt, "Etc/UTC"))

  defp ago(%DateTime{} = dt) do
    case DateTime.diff(DateTime.utc_now(), dt, :second) do
      s when abs(s) < 5 -> "agora"
      s when s < 0 -> "daqui a #{relative_duration(-s)}"
      s -> "há #{relative_duration(s)}"
    end
  end

  defp relative_duration(s) when s < 60, do: "#{s}s"
  defp relative_duration(s) when s < 3_600, do: "#{div(s, 60)}min"
  defp relative_duration(s) when s < 86_400, do: "#{div(s, 3_600)}h"
  defp relative_duration(s), do: "#{div(s, 86_400)}d"

  # ── Errors / extra detail ──────────────────────────────────────────────────

  defp full_url(%Oban.Job{args: args}), do: args["url"] || args["title"] || ""

  defp all_errors(%Oban.Job{errors: errors}) do
    Enum.map(errors, fn e ->
      attempt = e["attempt"] || "?"
      msg = e["error"] || inspect(e)
      "tentativa #{attempt}: #{msg}"
    end)
  end

  defp last_error(%Oban.Job{errors: []}), do: nil

  defp last_error(%Oban.Job{errors: errors}) do
    case List.last(errors) do
      %{"error" => e} -> e |> to_string() |> String.slice(0, 160)
      _ -> nil
    end
  end

  # ── State labels / colors ──────────────────────────────────────────────────

  defp state_label("available"), do: "Na fila"
  defp state_label("scheduled"), do: "Agendada"
  defp state_label("executing"), do: "Executando"
  defp state_label("retryable"), do: "Nova tentativa"
  defp state_label("suspended"), do: "Pausada"
  defp state_label("completed"), do: "Concluída"
  defp state_label("discarded"), do: "Descartada"
  defp state_label("cancelled"), do: "Cancelada"
  defp state_label(s), do: s

  defp state_class("completed"), do: "bg-green/15 text-green"
  defp state_class("executing"), do: "bg-primary/15 text-primary"
  defp state_class(s) when s in ["discarded", "cancelled"], do: "bg-coral/15 text-coral"
  defp state_class(s) when s in ["retryable", "suspended"], do: "bg-amber/15 text-amber"
  defp state_class(_), do: "bg-white/10 text-ink-muted"

  defp chip_class(true), do: "border-primary/60 bg-primary/15 text-ink"
  defp chip_class(false), do: "border-white/8 bg-input text-ink-muted hover:border-white/20"
end
