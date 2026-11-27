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

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, return_to: maintenance_origin(params["origem"]))}
  end

  defp maintenance_origin("volume"),
    do: %{
      key: :target_lufs,
      path: ~p"/manutencao" <> "#maintenance-gain",
      label: "Voltar à aplicação de ganho"
    }

  defp maintenance_origin("backup"),
    do: %{
      key: :backup_keep,
      path: ~p"/manutencao" <> "#maintenance-backup",
      label: "Voltar ao backup da curadoria"
    }

  defp maintenance_origin(_), do: nil

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
      {:noreply, socket |> assign(toast: {:ok, key, "Valor salvo."}) |> load()}
    else
      nil ->
        {:noreply, socket}

      :error ->
        {:noreply,
         assign(socket, toast: {:error, key, "Valor inválido. Confira a faixa permitida."})}
    end
  end

  def handle_event("reset", %{"key" => key}, socket) do
    case Registry.by_param(key) do
      nil ->
        {:noreply, socket}

      entry ->
        :ok = Settings.delete(entry.key)
        {:noreply, socket |> assign(toast: {:ok, key, "Valor padrão restaurado."}) |> load()}
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
            :if={is_nil(@return_to)}
            id="ajustes-maintenance"
            navigate={~p"/manutencao"}
            class="inline-flex items-center gap-2 rounded-md border border-white/10 bg-input px-3 py-2 text-body-sm font-semibold text-ink-secondary hover:text-ink"
          >
            Manutenção da biblioteca <.icon name="hero-arrow-right-mini" class="size-4" />
          </.link>
        </div>
      </header>

      <div class="mx-auto max-w-[1100px] px-3 py-5 sm:px-6">
        <div class="space-y-6">
          <section :for={{title, entries} <- @groups} :if={entries != []}>
            <h2 class="mb-2 text-[18px] font-semibold">{title}</h2>
            <div class="divide-y divide-white/8 rounded-xl border border-white/8 bg-surface px-4">
              <section
                :for={e <- entries}
                id={"ajuste-card-#{e.key}"}
                class="grid gap-3 py-4 lg:grid-cols-[minmax(0,1fr)_23rem] lg:items-start"
              >
                <div class="min-w-0">
                  <label for={"ajuste-value-#{e.key}"} class="text-body-lg font-semibold">{e.label}</label>
                  <span :if={e.override?} class="ml-1 text-caption font-semibold text-amber">personalizado</span>
                  <p
                    id={"ajuste-description-#{e.key}"}
                    class="mt-1 max-w-prose text-body text-ink-muted"
                  >
                    {e.description}
                  </p>
                </div>

                <div class="space-y-1.5">
                  <form
                    id={"ajuste-#{e.key}"}
                    phx-submit="save"
                    phx-auto-recover="ignore"
                    class="flex flex-wrap items-center gap-2"
                  >
                    <input type="hidden" name="key" value={e.key} />
                    <div class="flex min-w-0 items-center gap-1.5">
                      <input
                        id={"ajuste-value-#{e.key}"}
                        type="number"
                        name="value"
                        value={e.current}
                        aria-describedby={"ajuste-range-#{e.key} ajuste-description-#{e.key}"}
                        aria-invalid={
                          if @toast && elem(@toast, 0) == :error &&
                               elem(@toast, 1) == to_string(e.key), do: "true", else: "false"
                        }
                        required
                        step={if e.type == :integer, do: "1", else: "any"}
                        min={e.min}
                        max={e.max}
                        class="w-28 scroll-mt-20 rounded-md border border-white/10 bg-input px-3 py-2 font-mono text-body tabular-nums focus:border-primary/50"
                      />
                      <span :if={e.unit} class="text-body-sm text-ink-muted">{e.unit}</span>
                    </div>
                    <button class="rounded-md border border-primary/30 bg-primary/10 px-3 py-2 text-body-sm font-semibold text-primary hover:bg-primary/15">Salvar</button>
                    <button
                      :if={e.override?}
                      type="button"
                      phx-click="reset"
                      phx-value-key={e.key}
                      class="rounded-md border border-white/10 bg-input px-2.5 py-2 text-body-sm text-ink-secondary hover:text-ink"
                    >
                      Restaurar padrão
                    </button>
                  </form>

                  <p id={"ajuste-range-#{e.key}"} class="text-body-sm text-ink-muted">
                    Valor padrão <span class="font-mono tabular-nums">{e.default}</span>{if e.unit,
                      do: " #{e.unit}"}
                    <span aria-hidden="true"> · </span>
                    Faixa <span class="font-mono tabular-nums">{e.min}</span>
                    {if e.max, do: " a ", else: " ou mais"}<span
                      :if={e.max}
                      class="font-mono tabular-nums"
                    >{e.max}</span>
                  </p>
                  <div
                    :if={@toast && elem(@toast, 1) == to_string(e.key)}
                    class="flex items-center gap-2"
                  >
                    <p
                      role={if elem(@toast, 0) == :error, do: "alert", else: "status"}
                      class={[
                        "text-body-sm",
                        if(elem(@toast, 0) == :error, do: "text-coral", else: "text-green")
                      ]}
                    >
                      {elem(@toast, 2)}
                    </p>
                    <button
                      type="button"
                      phx-click="dismiss_toast"
                      aria-label="Fechar aviso"
                      class="text-ink-muted hover:text-ink"
                    ><.icon name="hero-x-mark-mini" class="size-4" /></button>
                  </div>
                  <.link
                    :if={@return_to && @return_to.key == e.key}
                    id={"ajuste-return-#{e.key}"}
                    navigate={@return_to.path}
                    class="inline-flex items-center gap-1 text-body-sm text-primary hover:underline"
                  >
                    <.icon name="hero-arrow-left-mini" class="size-4" /> {@return_to.label}
                  </.link>
                </div>
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
