defmodule BeatgridWeb.RescueLive do
  @moduledoc "Resgate — census de integridade da biblioteca + restauração de backups e quarentena."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Rescue

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Rescue.subscribe()
    {:ok, socket |> assign(page_title: "Recuperação de arquivos", note: nil) |> load()}
  end

  defp load(socket) do
    assign(socket,
      progress: Rescue.progress(),
      damaged: Rescue.damaged(),
      quarantined: Rescue.quarantined()
    )
  end

  defp with_track(socket, track_id, fun) do
    case Tracks.get(track_id) do
      nil -> socket |> put_flash(:error, "Faixa não encontrada — atualize a página.") |> load()
      track -> fun.(track)
    end
  end

  @impl true
  def handle_info({:integrity_checked, _track_id}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("check_all", _params, socket) do
    {:ok, count} = Rescue.enqueue_check_all()

    {:noreply,
     socket
     |> assign(
       note:
         "Verificação de #{count} faixa(s) enfileirada. O diagnóstico se atualiza conforme os resultados chegam."
     )
     |> load()}
  end

  def handle_event("restore", %{"track" => id}, socket) do
    {:noreply,
     with_track(socket, id, fn track ->
       case Rescue.restore_from_backup(track) do
         {:ok, _restored} ->
           socket
           |> put_flash(
             :info,
             "Faixa restaurada do backup. Confira o áudio antes de reaplicar o ganho em Manutenção."
           )
           |> load()

         {:error, reason} ->
           put_flash(socket, :error, restore_error(reason))
       end
     end)}
  end

  def handle_event("restore_all", _params, socket) do
    {:ok, %{restored: restored, failed: failed}} = Rescue.restore_all_from_backup()

    message =
      if failed == 0,
        do: "#{restored} faixa(s) restaurada(s) do backup.",
        else: "#{restored} restaurada(s); #{failed} falharam — veja cada linha."

    {:noreply, socket |> put_flash(:info, message) |> load()}
  end

  def handle_event("unquarantine", %{"track" => id}, socket) do
    {:noreply,
     with_track(socket, id, fn track ->
       case Rescue.restore_from_quarantine(track) do
         {:ok, _restored} ->
           socket |> put_flash(:info, "De volta da quarentena, no caminho original.") |> load()

         {:error, _reason} ->
           put_flash(socket, :error, "Não consegui restaurar — o caminho original está ocupado?")
       end
     end)}
  end

  defp restore_error(:no_backup), do: "Sem backup no disco para esta faixa."
  defp restore_error(_reason), do: "A restauração falhou — o arquivo de backup está íntegro?"

  defp count(progress, status), do: Map.get(progress, status, 0)

  defp title(track), do: track.tag_title || track.filename

  defp restorable_count(damaged), do: Enum.count(damaged, &is_binary(&1.backup_rel))

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:resgate} socket={@socket}>
      <div class="mx-auto max-w-5xl px-4 py-5 sm:px-6">
        <header class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 class="text-[22px] font-semibold tracking-tight">Recuperação de arquivos</h1>
            <p class="mt-1 text-body text-ink-muted">
              Verifique arquivos ausentes ou corrompidos e restaure cópias do backup ou da quarentena.
            </p>
          </div>
          <button
            phx-click="check_all"
            class="inline-flex items-center gap-2 rounded-md bg-primary-deep px-3 py-2.5 text-body font-semibold text-white hover:bg-primary-deep/90 sm:py-2"
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> Verificar biblioteca
          </button>
        </header>

        <p :if={@note} role="status" class="mt-3 text-body text-ink-secondary">{@note}</p>

        <section class="mt-4" aria-labelledby="integrity-heading">
          <h2 id="integrity-heading" class="mb-2 text-body-lg font-semibold text-ink-secondary">
            Integridade da biblioteca
          </h2>
          <dl class="grid grid-cols-2 gap-3 rounded-xl border border-white/8 bg-surface p-4 sm:grid-cols-4">
            <div>
              <dt class="text-body-sm text-ink-muted">Íntegras</dt>
              <dd class="mt-1 font-mono text-[18px] font-semibold text-green">
                {count(@progress, :ok)}
              </dd>
            </div>
            <div>
              <dt class="text-body-sm text-ink-muted">Arquivos ausentes</dt>
              <dd class="mt-1 font-mono text-[18px] font-semibold text-coral">
                {count(@progress, :missing_file)}
              </dd>
            </div>
            <div>
              <dt class="text-body-sm text-ink-muted">Corrompidas</dt>
              <dd class="mt-1 font-mono text-[18px] font-semibold text-amber">
                {count(@progress, :corrupt)}
              </dd>
            </div>
            <div>
              <dt class="text-body-sm text-ink-muted">Sem verificação</dt>
              <dd class="mt-1 font-mono text-[18px] font-semibold text-ink-secondary">
                {count(@progress, :unchecked)}
              </dd>
            </div>
          </dl>
        </section>

        <nav aria-label="Categorias de recuperação" class="mt-4 grid grid-cols-2 gap-2">
          <a
            href="#arquivos-danificados"
            class="inline-flex min-w-0 items-center justify-between gap-2 rounded-md border border-white/10 bg-input px-3 py-2 text-body font-medium text-ink-secondary hover:text-ink"
          >
            <span>Arquivos danificados
            <span class="font-mono text-ink-muted">({length(@damaged)})</span></span>
            <.icon name="hero-arrow-down-mini" class="size-4 shrink-0" />
          </a>
          <a
            href="#quarentena"
            class="inline-flex min-w-0 items-center justify-between gap-2 rounded-md border border-white/10 bg-input px-3 py-2 text-body font-medium text-ink-secondary hover:text-ink"
          >
            <span>Quarentena <span class="font-mono text-ink-muted">({length(@quarantined)})</span></span>
            <.icon name="hero-arrow-down-mini" class="size-4 shrink-0" />
          </a>
        </nav>

        <section id="arquivos-danificados" class="mt-6">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="text-[18px] font-semibold">
                Arquivos danificados
                <span class="font-mono text-body-lg text-ink-muted">({length(@damaged)})</span>
              </h2>
              <p :if={@damaged != []} class="mt-1 text-body text-ink-muted">
                {restorable_count(@damaged)} com backup disponível
              </p>
            </div>
            <button
              :if={restorable_count(@damaged) > 0}
              phx-click="restore_all"
              data-confirm={"Restaurar #{restorable_count(@damaged)} faixa(s) a partir do backup pré-ganho? Depois confira o áudio antes de reaplicar o ganho em Manutenção."}
              class="rounded-md border border-primary/35 bg-primary/10 px-3 py-2 text-body font-semibold text-primary hover:bg-primary/15"
            >
              Restaurar todas com backup ({restorable_count(@damaged)})
            </button>
          </div>

          <p :if={@damaged == []} class="mt-2 text-body text-ink-muted">
            Nenhum arquivo danificado identificado. Verifique a biblioteca para atualizar o diagnóstico.
          </p>

          <ul
            :if={@damaged != []}
            class="mt-3 divide-y divide-white/6 rounded-xl border border-white/8 bg-surface"
          >
            <li
              :for={d <- @damaged}
              id={"arquivo-#{d.track.id}"}
              class="grid min-w-0 gap-3 px-4 py-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                  <.link
                    navigate={~p"/track/#{d.track.id}"}
                    class="min-w-0 break-words text-body-lg font-semibold text-ink hover:text-primary hover:underline"
                  >
                    {title(d.track)}
                  </.link>
                  <span
                    :if={d.track.integrity_status == :missing_file}
                    class="text-body-sm font-medium text-coral"
                  >
                    arquivo sumido
                  </span>
                  <span
                    :if={d.track.integrity_status == :corrupt}
                    class="text-body-sm font-medium text-amber"
                  >
                    áudio corrompido
                  </span>
                </div>
                <dl class="mt-2 text-body">
                  <dt class="text-caption text-ink-muted">Caminho do arquivo</dt>
                  <dd class="break-words font-mono text-body-sm text-ink-secondary [overflow-wrap:anywhere]">
                    {d.track.rel_path}
                  </dd>
                </dl>
                <details
                  :if={d.track.integrity_error not in [nil, ""]}
                  class="mt-2 text-body text-ink-secondary"
                >
                  <summary class="cursor-pointer text-ink-muted">Diagnóstico</summary>
                  <p class="mt-1 whitespace-pre-wrap break-words [overflow-wrap:anywhere]">
                    {d.track.integrity_error}
                  </p>
                </details>
              </div>
              <button
                :if={d.backup_rel}
                phx-click="restore"
                phx-value-track={d.track.id}
                data-confirm={"Restaurar “#{title(d.track)}” do backup pré-ganho no caminho #{d.track.rel_path}?"}
                aria-label={"Restaurar do backup: #{title(d.track)}"}
                class="justify-self-start rounded-md border border-primary/35 bg-primary/10 px-3 py-2 text-body font-semibold text-primary hover:bg-primary/15 sm:justify-self-end"
              >
                Restaurar do backup
              </button>
              <div
                :if={is_nil(d.backup_rel)}
                class="flex items-center gap-1.5 text-body-sm text-ink-secondary"
              >
                <.icon name="hero-information-circle" class="size-4 shrink-0 text-ink-muted" />
                Sem backup
              </div>
            </li>
          </ul>
        </section>

        <section id="quarentena" class="mt-6">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-[18px] font-semibold">
              Quarentena
              <span class="font-mono text-body-lg text-ink-muted">({length(@quarantined)})</span>
            </h2>
            <.link navigate={~p"/dedup"} class="text-body-sm text-primary hover:underline">
              Revisar duplicatas
            </.link>
          </div>
          <p class="mt-1 text-body text-ink-muted">
            A restauração devolve o arquivo à pasta de origem.
          </p>

          <p :if={@quarantined == []} class="mt-2 text-body text-ink-muted">Quarentena vazia.</p>

          <ul
            :if={@quarantined != []}
            class="mt-3 divide-y divide-white/6 rounded-xl border border-white/8 bg-surface"
          >
            <li
              :for={q <- @quarantined}
              id={"arquivo-#{q.track.id}"}
              class="grid min-w-0 gap-3 px-4 py-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start"
            >
              <div class="min-w-0">
                <p class="break-words text-body-lg font-semibold text-ink">{title(q.track)}</p>
                <dl class="mt-2 text-body">
                  <dt class="text-caption text-ink-muted">Destino original</dt>
                  <dd class="break-words font-mono text-body-sm text-ink-secondary [overflow-wrap:anywhere]">
                    {q.restore_rel || "Origem desconhecida"}
                  </dd>
                </dl>
              </div>
              <button
                :if={q.restore_rel && q.file?}
                phx-click="unquarantine"
                phx-value-track={q.track.id}
                aria-label={"Restaurar #{title(q.track)} à origem"}
                class="justify-self-start rounded-md border border-primary/35 bg-primary/10 px-3 py-2 text-body font-semibold text-primary hover:bg-primary/15 sm:justify-self-end"
              >
                Restaurar à origem
              </button>
              <span
                :if={!q.file?}
                class="flex items-center gap-1.5 text-body-sm font-medium text-amber"
              >
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                Arquivo ausente na quarentena
              </span>
              <span
                :if={q.file? and is_nil(q.restore_rel)}
                class="flex items-center gap-1.5 text-body-sm text-ink-secondary"
              >
                <.icon name="hero-information-circle" class="size-4 shrink-0 text-ink-muted" />
                Pasta de origem desconhecida
              </span>
            </li>
          </ul>
        </section>
      </div>
    </.app_shell>
    """
  end
end
