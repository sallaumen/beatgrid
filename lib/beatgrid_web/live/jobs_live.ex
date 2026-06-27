defmodule BeatgridWeb.JobsLive do
  @moduledoc """
  Background-jobs visibility: a live view of recent Oban jobs across all queues,
  with their state + last error, and retry/cancel actions.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Jobs

  @refresh_ms 2_000
  @states ~w(available scheduled executing retryable completed discarded cancelled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, assign(socket, filter: nil, jobs: load(nil), states: @states, expanded: MapSet.new())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, jobs: load(socket.assigns.filter))}
  end

  @impl true
  def handle_event("filter", %{"state" => state}, socket) do
    filter = if state == "", do: nil, else: state
    {:noreply, assign(socket, filter: filter, jobs: load(filter))}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    Jobs.retry(String.to_integer(id))
    {:noreply, assign(socket, jobs: load(socket.assigns.filter))}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    Jobs.cancel(String.to_integer(id))
    {:noreply, assign(socket, jobs: load(socket.assigns.filter))}
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

  defp load(nil), do: Jobs.list_recent(limit: 100)
  defp load(state), do: Jobs.list_recent(limit: 100, states: [state])

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:jobs} socket={@socket}>
      <div class="mx-auto max-w-5xl px-6 py-8">
        <h1 class="text-[22px] font-semibold">Jobs</h1>
        <p class="text-ink-muted mt-1 text-body-sm">
          Tarefas em segundo plano (downloads, análise, IA, Soundcharts). Atualiza sozinho.
        </p>

        <div class="mt-4 flex flex-wrap gap-1.5">
          <button
            phx-click="filter"
            phx-value-state=""
            class={["rounded-sm border px-2.5 py-1 text-[12px]", chip_class(@filter == nil)]}
          >
            Todas
          </button>
          <button
            :for={s <- @states}
            phx-click="filter"
            phx-value-state={s}
            class={["rounded-sm border px-2.5 py-1 text-[12px]", chip_class(@filter == s)]}
          >
            {state_label(s)}
          </button>
        </div>

        <div class="mt-4 space-y-1">
          <div
            :for={j <- @jobs}
            class="rounded-lg border border-white/6 bg-surface px-3 py-2"
          >
            <div class="flex items-center gap-3">
              <span class={[
                "rounded-sm px-2 py-0.5 text-[10px] font-bold uppercase",
                state_class(j.state)
              ]}>
                {state_label(j.state)}
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate text-body-sm font-medium">{worker_label(j.worker)}</p>
                <p class="text-ink-muted truncate text-caption font-mono">{job_summary(j)}</p>
                <p :if={last_error(j)} class="text-coral truncate text-caption">{last_error(j)}</p>
              </div>
              <span class="text-ink-faint shrink-0 font-mono text-[11px]">{j.attempt}/{j.max_attempts}</span>
              <div class="flex shrink-0 items-center gap-1.5">
                <button
                  :if={j.errors != []}
                  type="button"
                  phx-click="toggle_details"
                  phx-value-id={j.id}
                  class="text-ink-faint hover:text-ink text-[11px]"
                >
                  {if MapSet.member?(@expanded, j.id), do: "Ocultar", else: "Detalhes"}
                </button>
                <button
                  :if={j.state in ["retryable", "discarded", "cancelled"]}
                  phx-click="retry"
                  phx-value-id={j.id}
                  class="rounded-md bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/25"
                >
                  Re-tentar
                </button>
                <button
                  :if={j.state in ["available", "scheduled", "executing", "retryable"]}
                  phx-click="cancel"
                  phx-value-id={j.id}
                  class="rounded-md bg-coral/10 px-2.5 py-1 text-[11px] text-coral hover:bg-coral/20"
                >
                  Cancelar
                </button>
              </div>
            </div>
            <div
              :if={MapSet.member?(@expanded, j.id)}
              class="mt-1 space-y-1 rounded-md bg-base px-3 py-2"
            >
              <p class="text-ink-muted break-all font-mono text-[11px]">{full_url(j)}</p>
              <p
                :for={line <- all_errors(j)}
                class="text-coral break-all whitespace-pre-wrap font-mono text-[11px]"
              >
                {line}
              </p>
            </div>
          </div>
          <p :if={@jobs == []} class="text-ink-faint py-12 text-center text-body-sm">
            Nenhuma tarefa.
          </p>
        </div>
      </div>
    </.app_shell>
    """
  end

  defp full_url(%Oban.Job{args: args}), do: args["url"] || args["title"] || ""

  defp all_errors(%Oban.Job{errors: errors}) do
    Enum.map(errors, fn e ->
      attempt = e["attempt"] || "?"
      msg = e["error"] || inspect(e)
      "tentativa #{attempt}: #{msg}"
    end)
  end

  defp worker_name(worker), do: worker |> String.split(".") |> List.last()

  # Friendly PT-BR labels per worker; falls back to the bare module segment so a
  # newly-added worker still renders something readable without editing this map.
  @worker_labels %{
    "EnrichWorker" => "Enriquecer",
    "AnalyzeWorker" => "Analisar",
    "ReResolveWorker" => "Re-resolver",
    "DownloadWorker" => "Baixar",
    "ReevaluateWorker" => "Re-avaliar",
    "ResolveSongWorker" => "Resolver",
    "ScanWorker" => "Escanear",
    "DedupWorker" => "Dedup",
    "ExpandWorker" => "Expandir"
  }

  defp worker_label(worker) do
    name = worker_name(worker)
    Map.get(@worker_labels, name, name)
  end

  defp job_summary(%Oban.Job{args: args}) do
    args["url"] || args["title"] || args |> Map.keys() |> Enum.join(", ")
  end

  defp last_error(%Oban.Job{errors: []}), do: nil

  defp last_error(%Oban.Job{errors: errors}) do
    case List.last(errors) do
      %{"error" => e} -> e |> to_string() |> String.slice(0, 160)
      _ -> nil
    end
  end

  defp state_label("available"), do: "Na fila"
  defp state_label("scheduled"), do: "Agendada"
  defp state_label("executing"), do: "Executando"
  defp state_label("retryable"), do: "Retentável"
  defp state_label("completed"), do: "Concluída"
  defp state_label("discarded"), do: "Descartada"
  defp state_label("cancelled"), do: "Cancelada"
  defp state_label(s), do: s

  defp state_class("completed"), do: "bg-green/15 text-green"
  defp state_class("executing"), do: "bg-primary/15 text-primary"
  defp state_class(s) when s in ["discarded", "cancelled"], do: "bg-coral/15 text-coral"
  defp state_class("retryable"), do: "bg-amber/15 text-amber"
  defp state_class(_), do: "bg-white/10 text-ink-muted"

  defp chip_class(true), do: "border-primary/60 bg-primary/20 text-ink"
  defp chip_class(false), do: "border-white/8 bg-input text-ink-muted hover:border-white/20"
end
