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

  # --- per-card decisions (toggle back to pending on a repeat click) ---

  def handle_event("approve", %{"id" => id, "type" => type}, socket) do
    s = find(socket, id, type)
    if s.status == :approved, do: Review.reset(s), else: Review.approve(s)
    {:noreply, load(socket)}
  end

  def handle_event("reject", %{"id" => id, "type" => type}, socket) do
    s = find(socket, id, type)
    if s.status == :rejected, do: Review.reset(s), else: Review.reject(s)
    {:noreply, load(socket)}
  end

  def handle_event("edit_start", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing: id)}

  def handle_event("edit_cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("edit_save", %{"sid" => id, "type" => type, "value" => value}, socket) do
    Review.edit(find(socket, id, type), value)
    {:noreply, socket |> assign(editing: nil) |> load()}
  end

  def handle_event("approve_high", _params, socket) do
    Review.approve_high_confidence(high_tab(socket.assigns.tab))
    {:noreply, load(socket)}
  end

  # --- apply to disk + undo (async so the UI stays responsive) ---

  def handle_event("apply", _params, socket) do
    {:noreply,
     socket
     |> assign(applying?: true, toast: nil)
     |> start_async(:apply, &Review.apply_approved/0)}
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
    {:noreply, socket |> assign(applying?: false, toast: {:applied, result}) |> load()}
  end

  def handle_async(:undo, {:ok, {:ok, result}}, socket) do
    {:noreply, socket |> assign(applying?: false, toast: {:undone, result}) |> load()}
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

  defp high_tab(:classifications), do: :classifications
  defp high_tab(_), do: :renames

  defp rename_items(:auditoria, renames), do: Enum.filter(renames, &audit_flag(&1.reason))
  defp rename_items(_tab, renames), do: renames

  defp current_items(:classifications, _renames, classifications), do: classifications
  defp current_items(tab, renames, _classifications), do: rename_items(tab, renames)

  defp approved_total(renames, classifications) do
    Enum.count(renames, &(&1.status == :approved)) +
      Enum.count(classifications, &(&1.status == :approved))
  end

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
    <.app_shell active={:revisao}>
      <div class="flex h-screen flex-col">
        <header class="border-b border-white/6 bg-rail px-5 pt-3">
          <div class="flex items-center justify-between gap-4">
            <h2 class="text-[22px] font-semibold">Central de Revisão</h2>
            <div class="flex items-center gap-2">
              <button
                :if={@tab != :auditoria}
                phx-click="approve_high"
                class="rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
              >
                Aprovar todas de alta confiança
              </button>
              <button
                phx-click="apply"
                disabled={@applying? or approved_total(@renames, @classifications) == 0}
                class="rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-40"
              >
                {if @applying?,
                  do: "Aplicando…",
                  else: "Aplicar #{approved_total(@renames, @classifications)} no disco"}
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
            {count_summary(@items)}
          </p>

          <div :if={@items != []} class="space-y-2.5">
            <%= for s <- @items do %>
              <.suggestion_card
                :if={@tab == :classifications}
                id={s.id}
                type={:classification}
                status={s.status}
                editing={@editing == s.id}
                artist={artist_of(s.track)}
                title={card_title(s.track)}
                from_folder={s.track && s.track.genre_folder}
                to={s.to_genre_folder}
                confidence_level={move_level(s.confidence)}
                rationale={s.reason}
                folders={@folders}
              />
              <.suggestion_card
                :if={@tab != :classifications}
                id={s.id}
                type={:rename}
                status={s.status}
                editing={@editing == s.id}
                artist={artist_of(s.track)}
                title={card_title(s.track)}
                from={s.from_filename}
                to={s.to_filename}
                confidence_level={s.confidence}
                audit={audit_flag(s.reason)}
              />
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
  defp toast_message({:error, _reason}), do: "Falha ao aplicar. Nada foi alterado."

  defp count_summary(items) do
    n = fn status -> Enum.count(items, &(&1.status == status)) end
    "#{n.(:pending)} pendentes · #{n.(:approved)} aprovadas · #{n.(:rejected)} rejeitadas"
  end
end
