defmodule BeatgridWeb.ReviewLive do
  @moduledoc "Central de Revisão — approve/edit/reject suggestions, then apply to disk."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.GenreFolders
  alias Beatgrid.{Operations, Review}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Central de Revisão",
       tab: :renames,
       editing: nil,
       toast: nil,
       applying?: false,
       selected: MapSet.new(),
       folders: GenreFolders.list()
     )
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      renames: Review.queue_renames(),
      classifications: Review.queue_classifications()
    )
  end

  # --- navigation ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab_atom(tab), editing: nil)}
  end

  # --- selection (ephemeral; no DB writes, so the list never reorders) ---

  def handle_event("toggle_select", %{"id" => id}, socket) do
    {:noreply, update(socket, :selected, &toggle(&1, id))}
  end

  def handle_event("select_all", _params, socket) do
    ids = socket.assigns |> tab_items() |> Enum.map(& &1.id)
    {:noreply, update(socket, :selected, &MapSet.union(&1, MapSet.new(ids)))}
  end

  def handle_event("select_high", _params, socket) do
    ids = socket.assigns |> tab_items() |> Enum.filter(&high_confidence?/1) |> Enum.map(& &1.id)
    {:noreply, update(socket, :selected, &MapSet.union(&1, MapSet.new(ids)))}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, assign(socket, selected: MapSet.new())}

  # --- per-card decisions ---

  def handle_event("reject", %{"id" => id, "type" => type}, socket) do
    s = find(socket, id, type)
    if s.status == :rejected, do: Review.reset(s), else: Review.reject(s)
    {:noreply, socket |> update(:selected, &MapSet.delete(&1, id)) |> load()}
  end

  def handle_event("edit_start", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing: id)}

  def handle_event("edit_cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("edit_save", %{"sid" => id, "type" => type, "value" => value}, socket) do
    Review.edit(find(socket, id, type), value)
    {:noreply, socket |> assign(editing: nil) |> update(:selected, &MapSet.put(&1, id)) |> load()}
  end

  # --- audit-tab actions ---

  def handle_event("dismiss_audit", %{"id" => id}, socket) do
    socket.assigns.renames |> Enum.find(&(&1.id == id)) |> Review.dismiss_audit()
    {:noreply, load(socket)}
  end

  def handle_event("quarantine", %{"id" => id}, socket) do
    s = Enum.find(socket.assigns.renames, &(&1.id == id))

    toast =
      case Review.quarantine_track(s) do
        {:ok, _} -> {:quarantined, %{}}
        _ -> {:error, :quarantine}
      end

    {:noreply, socket |> assign(toast: toast) |> load()}
  end

  def handle_event("re_resolve", %{"id" => id}, socket) do
    s = Enum.find(socket.assigns.renames, &(&1.id == id))

    {:noreply,
     socket
     |> assign(toast: {:resolving, %{}})
     |> start_async(:re_resolve, fn -> Review.re_resolve(s) end)}
  end

  # --- apply to disk + undo (async so the UI stays responsive) ---

  def handle_event("apply", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    {:noreply,
     socket
     |> assign(applying?: true, toast: nil)
     |> start_async(:apply, fn -> Review.apply_selected(ids) end)}
  end

  def handle_event("undo", %{"batch" => batch}, socket) do
    {:noreply,
     socket
     |> assign(applying?: true)
     |> start_async(:undo, fn -> Operations.undo_batch(batch) end)}
  end

  def handle_event("dismiss_toast", _params, socket), do: {:noreply, assign(socket, toast: nil)}

  @impl true
  def handle_async(:apply, {:ok, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> assign(applying?: false, selected: MapSet.new(), toast: {:applied, result})
     |> load()}
  end

  def handle_async(:undo, {:ok, {:ok, result}}, socket) do
    {:noreply, socket |> assign(applying?: false, toast: {:undone, result}) |> load()}
  end

  def handle_async(:re_resolve, {:ok, {:ok, outcome}}, socket) do
    {:noreply, socket |> assign(toast: {outcome, %{}}) |> load()}
  end

  def handle_async(:re_resolve, {:ok, {:error, _reason}}, socket) do
    {:noreply, assign(socket, toast: {:error, :re_resolve})}
  end

  def handle_async(_name, {:exit, reason}, socket) do
    {:noreply, assign(socket, applying?: false, toast: {:error, reason})}
  end

  # --- helpers ---

  defp find(socket, id, "classification"),
    do: Enum.find(socket.assigns.classifications, &(&1.id == id))

  defp find(socket, id, _rename), do: Enum.find(socket.assigns.renames, &(&1.id == id))

  defp tab_atom("classifications"), do: :classifications
  defp tab_atom("auditoria"), do: :auditoria
  defp tab_atom(_), do: :renames

  defp rename_items(:auditoria, renames), do: Enum.filter(renames, &audit_flag(&1.reason))
  defp rename_items(_tab, renames), do: renames

  defp current_items(:classifications, _renames, classifications), do: classifications
  defp current_items(tab, renames, _classifications), do: rename_items(tab, renames)

  defp tab_items(assigns),
    do: current_items(assigns.tab, assigns.renames, assigns.classifications)

  defp toggle(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  # high-confidence = rename match :high, or classification score >= 0.8
  defp high_confidence?(%{confidence: :high}), do: true
  defp high_confidence?(%{confidence: c}) when is_float(c), do: c >= 0.8
  defp high_confidence?(_), do: false

  defp audit_flag(reason) when is_binary(reason) do
    case Regex.run(~r/^\[audit:([^\]]+)\]/, reason) do
      [_, tag] -> tag
      _ -> nil
    end
  end

  defp audit_flag(_reason), do: nil

  defp move_level(c) when is_float(c) and c >= 0.8, do: :high
  defp move_level(c) when is_float(c) and c >= 0.5, do: :medium
  defp move_level(_c), do: :low

  defp card_title(%{tag_title: t}) when is_binary(t) and t != "", do: t
  defp card_title(%{filename: f}), do: f
  defp card_title(_track), do: "—"

  defp artist_of(%{tag_artist: a}), do: a
  defp artist_of(_track), do: nil

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, items: current_items(assigns.tab, assigns.renames, assigns.classifications))

    ~H"""
    <.app_shell active={:revisao} socket={@socket}>
      <div class="flex h-screen flex-col">
        <header class="border-b border-white/6 bg-rail px-5 pt-3">
          <div class="flex items-center justify-between gap-4">
            <h2 class="text-[22px] font-semibold">Central de Revisão</h2>
            <div class="flex items-center gap-2">
              <button
                :if={@tab != :auditoria}
                phx-click="select_high"
                class="rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
              >
                Marcar alta confiança
              </button>
              <button
                :if={@tab != :auditoria}
                phx-click="select_all"
                class="rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
              >
                Marcar todas
              </button>
              <button
                :if={MapSet.size(@selected) > 0}
                phx-click="clear_selection"
                class="rounded-md px-2.5 py-1.5 text-body-sm text-ink-muted hover:text-ink"
              >
                Limpar
              </button>
              <button
                phx-click="apply"
                disabled={@applying? or MapSet.size(@selected) == 0}
                class="rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-40"
              >
                {if @applying?,
                  do: "Aplicando…",
                  else: "Aplicar #{MapSet.size(@selected)} no disco"}
              </button>
            </div>
          </div>

          <nav class="mt-3 flex gap-1">
            <.tab
              id="renames"
              label="Renomeações"
              count={length(@renames)}
              active={@tab == :renames}
            />
            <.tab
              id="classifications"
              label="Classificação"
              count={length(@classifications)}
              active={@tab == :classifications}
            />
            <.tab
              id="auditoria"
              label="Auditoria"
              count={length(rename_items(:auditoria, @renames))}
              active={@tab == :auditoria}
            />
          </nav>
        </header>

        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          <.toast :if={@toast} toast={@toast} />

          <p class="mb-3 text-caption text-ink-faint">
            {count_summary(@items, @selected)}
          </p>

          <div :if={@items != []} class="space-y-2.5">
            <%= for s <- @items do %>
              <.suggestion_card
                :if={@tab == :classifications}
                id={s.id}
                type={:classification}
                status={s.status}
                selected={MapSet.member?(@selected, s.id)}
                editing={@editing == s.id}
                artist={artist_of(s.track)}
                title={card_title(s.track)}
                from_folder={s.track && s.track.genre_folder}
                to={s.to_genre_folder}
                confidence_level={move_level(s.confidence)}
                rationale={s.reason}
                folders={@folders}
                audio_src={~p"/audio/#{s.track_id}"}
                track_id={s.track_id}
                cover_src={cover_src(s.track)}
              />
              <.suggestion_card
                :if={@tab == :renames}
                id={s.id}
                type={:rename}
                status={s.status}
                selected={MapSet.member?(@selected, s.id)}
                editing={@editing == s.id}
                artist={artist_of(s.track)}
                title={card_title(s.track)}
                from={s.from_filename}
                to={s.to_filename}
                confidence_level={s.confidence}
                audit={audit_flag(s.reason)}
                audio_src={~p"/audio/#{s.track_id}"}
                track_id={s.track_id}
                cover_src={cover_src(s.track)}
              />
              <.suggestion_card
                :if={@tab == :auditoria}
                id={s.id}
                type={:rename}
                status={s.status}
                selectable={false}
                editing={@editing == s.id}
                artist={artist_of(s.track)}
                title={card_title(s.track)}
                from={s.from_filename}
                to={s.to_filename}
                confidence_level={s.confidence}
                audit={audit_flag(s.reason)}
                audio_src={~p"/audio/#{s.track_id}"}
                track_id={s.track_id}
                cover_src={cover_src(s.track)}
              >
                <:extra>
                  <button
                    phx-click="re_resolve"
                    phx-value-id={s.id}
                    data-confirm="Re-resolver gasta chamadas da cota Soundcharts. Continuar?"
                    class="rounded-md bg-input px-2.5 py-1 text-[11px] text-ink-muted hover:text-ink"
                  >
                    Re-resolver
                  </button>
                  <button
                    phx-click="dismiss_audit"
                    phx-value-id={s.id}
                    class="rounded-md bg-input px-2.5 py-1 text-[11px] text-ink-muted hover:text-ink"
                  >
                    Ignorar flag
                  </button>
                  <button
                    phx-click="quarantine"
                    phx-value-id={s.id}
                    data-confirm="Mover esta faixa para _Quarantine no disco?"
                    class="rounded-md bg-coral/10 px-2.5 py-1 text-[11px] text-coral hover:bg-coral/20"
                  >
                    Quarentena
                  </button>
                </:extra>
              </.suggestion_card>
            <% end %>
          </div>

          <div
            :if={@items == []}
            class="flex flex-col items-center justify-center gap-2 py-24 text-center"
          >
            <span class="hero-check-circle size-10 text-ink-disabled" />
            <p class="text-ink-muted">Nada pendente nesta aba.</p>
          </div>
        </div>
      </div>
    </.app_shell>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :active, :boolean, required: true

  defp tab(assigns) do
    ~H"""
    <button
      phx-click="switch_tab"
      phx-value-tab={@id}
      class={[
        "flex items-center gap-2 rounded-t-md px-3.5 py-2 text-body-sm font-medium transition-colors",
        @active && "bg-surface text-ink",
        !@active && "text-ink-muted hover:text-ink"
      ]}
    >
      {@label}
      <span class={[
        "rounded-full px-1.5 py-px font-mono text-[10px]",
        @active && "bg-primary/20 text-primary",
        !@active && "bg-white/8 text-ink-faint"
      ]}>
        {@count}
      </span>
    </button>
    """
  end

  attr :toast, :any, required: true

  defp toast(assigns) do
    ~H"""
    <div class="mb-4 flex items-center justify-between gap-4 rounded-lg border border-green/30 bg-green/10 px-4 py-2.5">
      <p class="text-body-sm text-ink">{toast_message(@toast)}</p>
      <div class="flex items-center gap-3">
        <button
          :if={match?({:applied, _}, @toast)}
          phx-click="undo"
          phx-value-batch={elem(@toast, 1).batch_id}
          class="text-body-sm font-semibold text-green hover:underline"
        >
          Desfazer
        </button>
        <button phx-click="dismiss_toast" class="text-ink-muted hover:text-ink text-body-sm">✕</button>
      </div>
    </div>
    """
  end

  defp toast_message({:applied, %{applied: n, failed: 0}}),
    do: "#{n} alterações aplicadas no disco."

  defp toast_message({:applied, %{applied: n, failed: f}}),
    do: "#{n} aplicadas no disco, #{f} falharam."

  defp toast_message({:undone, %{undone: n}}), do: "#{n} alterações desfeitas."
  defp toast_message({:quarantined, _}), do: "Faixa movida para _Quarantine."
  defp toast_message({:resolving, _}), do: "Re-resolvendo no Soundcharts…"
  defp toast_message({:resolved, _}), do: "Re-resolvido — confira a nova sugestão em Renomeações."
  defp toast_message({:no_match, _}), do: "Sem novo match no Soundcharts."
  defp toast_message({:error, _reason}), do: "Falha na operação. Nada foi alterado."

  defp count_summary(items, selected) do
    marked = Enum.count(items, &MapSet.member?(selected, &1.id))
    "#{length(items)} nesta aba · #{marked} marcada(s)"
  end
end
