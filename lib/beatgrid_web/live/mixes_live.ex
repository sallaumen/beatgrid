defmodule BeatgridWeb.MixesLive do
  @moduledoc "Curadoria: import + study recorded online DJ sets (SoundCloud) — the index/list."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Mixes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Mixes.subscribe()

    {:ok,
     assign(socket, page_title: "Sets online", mixes: Mixes.list_mixes(), url: "", toast: nil)}
  end

  @impl true
  def handle_event("import", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, socket}
    else
      case Mixes.import_url(url) do
        {:ok, _mix} ->
          {:noreply,
           assign(socket,
             mixes: Mixes.list_mixes(),
             url: "",
             toast: {:ok, "Set na fila — baixando…"}
           )}

        {:error, _changeset} ->
          {:noreply,
           assign(socket, toast: {:error, "Esse set já foi importado (ou URL inválida)."})}
      end
    end
  end

  @impl true
  def handle_info({:mix_progress, _payload}, socket) do
    {:noreply, assign(socket, mixes: Mixes.list_mixes())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:mixes} socket={@socket}>
      <div class="mx-auto max-w-[1600px] px-6 py-5">
        <header class="flex items-center justify-between gap-4">
          <h1 class="text-[22px] font-semibold">Sets online</h1>
        </header>

        <p :if={@toast} class="mt-3 text-body-sm text-ink-secondary">{elem(@toast, 1)}</p>

        <form id="mix-import-form" phx-submit="import" class="mt-4 flex gap-2">
          <input
            type="text"
            name="url"
            value={@url}
            placeholder="Cole a URL do set no SoundCloud…"
            class="min-w-0 flex-1 rounded-md border border-white/10 bg-surface px-3 py-2 text-body-sm"
          />
          <button class="rounded-md border border-primary/40 bg-primary/10 px-3 py-2 text-body-sm font-semibold text-primary hover:bg-primary/20">
            Importar
          </button>
        </form>

        <section class="mt-6 space-y-2">
          <p :if={@mixes == []} class="text-body-sm text-ink-muted">Nenhum set importado ainda.</p>
          <.link
            :for={mix <- @mixes}
            navigate={~p"/sets-online/#{mix.id}"}
            class="flex items-center justify-between gap-4 rounded-lg border border-white/6 bg-surface px-4 py-3 hover:border-white/12"
          >
            <div class="min-w-0">
              <p class="truncate font-medium">{mix.title || mix.source_url}</p>
              <p class="truncate text-body-sm text-ink-muted">{mix.dj || "—"}</p>
            </div>
            <span class="shrink-0 text-[11px] font-semibold uppercase tracking-wider text-ink-faint">
              {mix_status_label(mix.status)}
            </span>
          </.link>
        </section>
      </div>
    </.app_shell>
    """
  end

  defp mix_status_label(:downloading), do: "Baixando…"
  defp mix_status_label(:analyzing), do: "Analisando…"
  defp mix_status_label(:ready), do: "Pronto"
  defp mix_status_label(:failed), do: "Falhou"
end
