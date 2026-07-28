defmodule BeatgridWeb.RescueLive do
  @moduledoc "Resgate — census de integridade da biblioteca + restauração de backups e quarentena."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Rescue

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Rescue.subscribe()
    {:ok, socket |> assign(page_title: "Resgate", note: nil) |> load()}
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
     |> assign(note: "Verificando #{count} faixa(s) em background — o censo atualiza sozinho.")
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
             "Restaurada do backup — valide o som e re-aplique o ganho no Painel."
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
      <div class="mx-auto max-w-5xl px-4 py-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-[17px] font-semibold tracking-tight">Resgate</h1>
            <p class="text-[11px] text-ink-muted">
              Censo de integridade: arquivos sumidos ou que não decodificam mais, com restauração
              a partir dos backups de ganho e da quarentena.
            </p>
          </div>
          <button
            phx-click="check_all"
            class="rounded-lg bg-primary/15 px-3 py-2 text-[12px] font-semibold text-primary hover:bg-primary/25"
          >
            Verificar biblioteca
          </button>
        </div>

        <p :if={@note} class="mt-2 text-[11px] text-ink-muted">{@note}</p>

        <div class="mt-3 flex flex-wrap gap-2 text-[11px]">
          <span class="rounded-full border border-white/10 px-3 py-1 text-ink-secondary">
            ✓ íntegras: <b>{count(@progress, :ok)}</b>
          </span>
          <span class="rounded-full border border-coral/40 px-3 py-1 text-coral">
            arquivo sumido: <b>{count(@progress, :missing_file)}</b>
          </span>
          <span class="rounded-full border border-amber/40 px-3 py-1 text-amber">
            corrompidas: <b>{count(@progress, :corrupt)}</b>
          </span>
          <span class="rounded-full border border-white/10 px-3 py-1 text-ink-faint">
            sem verificação: <b>{count(@progress, :unchecked)}</b>
          </span>
        </div>

        <section class="mt-5">
          <div class="flex items-center justify-between gap-2">
            <h2 class="text-[13px] font-semibold">Danificadas ({length(@damaged)})</h2>
            <button
              :if={restorable_count(@damaged) > 0}
              phx-click="restore_all"
              data-confirm={"Restaurar #{restorable_count(@damaged)} faixa(s) a partir do backup pré-ganho? Depois valide o som e re-aplique o ganho no Painel."}
              class="rounded-lg bg-primary/15 px-3 py-1.5 text-[11px] font-semibold text-primary hover:bg-primary/25"
            >
              Restaurar todas com backup ({restorable_count(@damaged)})
            </button>
          </div>

          <p :if={@damaged == []} class="mt-2 text-[11px] text-ink-faint">
            Nenhuma faixa danificada conhecida — rode "Verificar biblioteca" para o censo completo.
          </p>

          <ul
            :if={@damaged != []}
            class="mt-2 divide-y divide-white/5 rounded-xl border border-white/8"
          >
            <li :for={d <- @damaged} class="flex items-center justify-between gap-3 px-3 py-2">
              <div class="min-w-0">
                <p class="truncate text-[12px] text-ink">{title(d.track)}</p>
                <p class="truncate text-[10px] text-ink-faint" title={d.track.integrity_error}>
                  {d.track.rel_path} ·
                  <span :if={d.track.integrity_status == :missing_file} class="text-coral">
                    arquivo sumido
                  </span>
                  <span :if={d.track.integrity_status == :corrupt} class="text-amber">
                    não decodifica
                  </span>
                </p>
              </div>
              <button
                :if={d.backup_rel}
                phx-click="restore"
                phx-value-track={d.track.id}
                class="shrink-0 rounded-lg bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/25"
              >
                Restaurar do backup
              </button>
              <span :if={is_nil(d.backup_rel)} class="shrink-0 text-[10px] text-ink-faint">
                sem backup
              </span>
            </li>
          </ul>
        </section>

        <section class="mt-6">
          <h2 class="text-[13px] font-semibold">Quarentena ({length(@quarantined)})</h2>
          <p class="mt-1 text-[10px] text-ink-muted">
            Cópias que o dedup moveu para <code>_Quarantine</code> — restaurar devolve ao caminho
            original.
          </p>

          <p :if={@quarantined == []} class="mt-2 text-[11px] text-ink-faint">Quarentena vazia.</p>

          <ul
            :if={@quarantined != []}
            class="mt-2 divide-y divide-white/5 rounded-xl border border-white/8"
          >
            <li :for={q <- @quarantined} class="flex items-center justify-between gap-3 px-3 py-2">
              <div class="min-w-0">
                <p class="truncate text-[12px] text-ink">{title(q.track)}</p>
                <p class="truncate text-[10px] text-ink-faint">
                  volta para: {q.restore_rel || "origem desconhecida"}
                </p>
              </div>
              <button
                :if={q.restore_rel}
                phx-click="unquarantine"
                phx-value-track={q.track.id}
                class="shrink-0 rounded-lg bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary hover:bg-primary/25"
              >
                Restaurar
              </button>
            </li>
          </ul>
        </section>
      </div>
    </.app_shell>
    """
  end
end
