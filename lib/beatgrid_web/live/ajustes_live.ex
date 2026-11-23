defmodule BeatgridWeb.AjustesLive do
  @moduledoc """
  Ajustes — the runtime tunables (`Beatgrid.Settings`) behind a screen. Renders
  every knob `Settings.Registry` declares with its effective value, the default,
  and a one-click restore; changes take effect immediately (the Settings cache
  invalidates on every write). Values are validated server-side against the
  registry's type + range — the client key is looked up, never atomized.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library
  alias Beatgrid.Settings
  alias Beatgrid.Settings.Registry

  @sections [
    {"Sets e discotecagem", [:breather_gap_s, :breather_every, :instrumental_min]},
    {"Áudio e backup", [:target_lufs, :gain_tolerance_db, :backup_keep]},
    {"Curadoria", [:gold_view_threshold, :auto_file_confidence]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Ajustes", toast: nil) |> load()}
  end

  defp load(socket) do
    entries =
      for entry <- Registry.all() do
        Map.merge(entry, %{current: entry.effective.(), override?: Registry.override?(entry.key)})
      end

    groups =
      Enum.map(@sections, fn {title, keys} ->
        {title, Enum.filter(entries, &(&1.key in keys))}
      end)

    grouped_keys = Enum.flat_map(@sections, &elem(&1, 1))
    other_entries = Enum.reject(entries, &(&1.key in grouped_keys))

    groups =
      if other_entries == [], do: groups, else: groups ++ [{"Outros ajustes", other_entries}]

    assign(socket, groups: groups)
  end

  @impl true
  def handle_event("save", %{"key" => key, "value" => value}, socket) do
    with %{} = entry <- Registry.by_param(key),
         {:ok, parsed} <- Registry.parse(entry.key, value) do
      {:ok, _} = Settings.put(entry.key, parsed)
      {:noreply, socket |> assign(toast: {:ok, "“#{entry.label}” salvo."}) |> load()}
    else
      nil ->
        {:noreply, socket}

      :error ->
        {:noreply, assign(socket, toast: {:error, "Valor inválido — confira o tipo e a faixa."})}
    end
  end

  def handle_event("reset", %{"key" => key}, socket) do
    case Registry.by_param(key) do
      nil ->
        {:noreply, socket}

      entry ->
        :ok = Settings.delete(entry.key)
        {:noreply, socket |> assign(toast: {:ok, "“#{entry.label}” voltou ao padrão."}) |> load()}
    end
  end

  def handle_event("dismiss_toast", _params, socket),
    do: {:noreply, assign(socket, toast: nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:ajustes} socket={@socket}>
      <header class="border-b border-white/6 bg-rail px-3 py-3 sm:px-6">
        <div class="mx-auto flex max-w-[1100px] flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-[22px] font-semibold">Ajustes</h1>
            <p class="text-body-sm text-ink-muted">As alterações entram em vigor ao salvar.</p>
          </div>
          <.link
            id="ajustes-maintenance"
            navigate={~p"/manutencao"}
            class="inline-flex items-center gap-2 rounded-md border border-white/10 bg-input px-3 py-2 text-body-sm font-semibold text-ink-secondary hover:text-ink"
          >
            Manutenção da biblioteca <.icon name="hero-arrow-right-mini" class="size-4" />
          </.link>
        </div>
      </header>

      <div class="mx-auto max-w-[1100px] px-3 py-5 sm:px-6">
        <div
          :if={@toast}
          class={[
            "mb-4 flex items-center justify-between gap-4 rounded-md border px-4 py-2 text-body-sm",
            elem(@toast, 0) == :ok && "border-primary/30 bg-primary/10 text-ink",
            elem(@toast, 0) == :error && "border-coral/40 bg-coral/10 text-coral"
          ]}
        >
          <span role="status">{elem(@toast, 1)}</span>
          <button
            phx-click="dismiss_toast"
            aria-label="Fechar aviso"
            class="text-ink-muted hover:text-ink"
          >
            ✕
          </button>
        </div>

        <div class="space-y-6">
          <section :for={{title, entries} <- @groups} :if={entries != []}>
            <h2 class="mb-2 text-[18px] font-semibold">{title}</h2>
            <div class="grid gap-3 lg:grid-cols-2">
              <section
                :for={e <- entries}
                id={"ajuste-card-#{e.key}"}
                class="flex flex-col rounded-xl border border-white/8 bg-surface p-4"
              >
                <div class="flex items-center justify-between gap-2">
                  <h3 class="text-body font-medium">{e.label}</h3>
                  <span
                    :if={e.override?}
                    class="rounded-full bg-amber/15 px-2 py-px text-[10px] font-semibold text-amber"
                  >
                    personalizado
                  </span>
                  <span
                    :if={!e.override?}
                    class="text-ink-faint rounded-full bg-white/5 px-2 py-px text-[10px] font-semibold"
                  >
                    padrão
                  </span>
                </div>

                <p class="text-ink-muted mt-1 flex-1 text-body-sm">{e.description}</p>

                <form
                  id={"ajuste-#{e.key}"}
                  phx-submit="save"
                  class="mt-3 flex flex-wrap items-center gap-2"
                >
                  <input type="hidden" name="key" value={e.key} />
                  <input
                    type="number"
                    name="value"
                    value={e.current}
                    aria-label={e.label}
                    step={if e.type == :integer, do: "1", else: "any"}
                    min={e.min}
                    max={e.max}
                    class="w-32 rounded-md border border-white/8 bg-input px-3 py-1.5 font-mono text-body-sm tabular-nums focus:border-primary/50"
                  />
                  <span :if={e.unit} class="text-ink-faint text-caption">{e.unit}</span>
                  <button class="rounded-md bg-primary-deep px-3 py-1.5 text-body-sm font-semibold text-white">
                    Salvar
                  </button>
                  <button
                    :if={e.override?}
                    type="button"
                    phx-click="reset"
                    phx-value-key={e.key}
                    class="rounded-md border border-white/10 bg-input px-2.5 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
                  >
                    Restaurar padrão
                  </button>
                </form>

                <p class="text-ink-faint mt-2 text-caption">
                  Padrão: {e.default}{if e.unit, do: " #{e.unit}"} · faixa: {e.min}{if e.max,
                    do: " a #{e.max}",
                    else: " ou mais"}
                </p>
              </section>
            </div>
          </section>
        </div>

        <p class="text-ink-faint mt-6 text-caption">
          Pasta da biblioteca <span class="ml-1 break-all font-mono">{Library.library_root()}</span>
        </p>
      </div>
    </.app_shell>
    """
  end
end
