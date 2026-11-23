defmodule BeatgridWeb.MixesLive do
  @moduledoc "Curadoria: import + study recorded online DJ sets (SoundCloud) — the index/list."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Mixes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Mixes.subscribe()

    {:ok,
     assign(socket, page_title: "Sets gravados", mixes: Mixes.list_mixes(), url: "", toast: nil)}
  end

  @impl true
  def handle_event("import", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, socket}
    else
      socket = assign(socket, url: url)

      case Mixes.import_url(url) do
        {:ok, _mix} ->
          {:noreply,
           assign(socket,
             mixes: Mixes.list_mixes(),
             url: "",
             toast: {:ok, "Set na fila — baixando…"}
           )}

        {:error, :unsupported_source} ->
          {:noreply,
           assign(socket,
             toast: {:error, "Cole um link do YouTube ou SoundCloud."}
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
    <.app_shell flash={@flash} active={:mixes} socket={@socket}>
      <div class="mx-auto max-w-[1600px] px-6 py-5">
        <header class="flex flex-col gap-1">
          <h1 class="text-[22px] font-semibold">Sets gravados</h1>
        </header>

        <form id="mix-import-form" phx-submit="import" class="mt-4">
          <label for="mix-source-url" class="mb-1 block text-body-sm text-ink-secondary">
            Link do YouTube ou SoundCloud
          </label>
          <div class="flex flex-wrap gap-2">
            <input
              id="mix-source-url"
              type="text"
              name="url"
              value={@url}
              required
              placeholder="Cole o link da gravação"
              class="min-w-0 flex-1 rounded-md border border-white/10 bg-surface px-3 py-2 text-body-sm"
            />
            <button class="rounded-md bg-primary-deep px-3 py-2 text-body-sm font-semibold text-white hover:bg-primary-deep/90">
              Importar gravação
            </button>
          </div>
        </form>

        <p
          :if={@toast}
          role="status"
          class={[
            "mt-3 text-body-sm",
            (elem(@toast, 0) == :error && "text-coral") || "text-ink-secondary"
          ]}
        >
          {elem(@toast, 1)}
        </p>

        <section class="mt-6 space-y-2">
          <p :if={@mixes == []} class="text-body-sm text-ink-muted">
            Importe uma gravação para conferir as faixas, estudar as transições e salvar recortes na biblioteca.
          </p>
          <article
            :for={mix <- @mixes}
            class="rounded-lg border border-white/6 bg-surface px-4 py-3 hover:border-white/12"
          >
            <div class="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <.link
                    navigate={~p"/sets-online/#{mix.id}"}
                    class="min-w-0 break-words text-body font-semibold text-ink hover:text-primary"
                  >
                    {mix.title || mix.source_url}
                  </.link>
                  <span class="shrink-0 rounded-full border border-white/8 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
                    {mix_status_label(mix.status)}
                  </span>
                </div>
                <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-body-sm text-ink-muted">
                  <span>{mix.dj || "DJ desconhecido"}</span>
                  <a
                    href={mix.source_url}
                    target="_blank"
                    rel="noopener"
                    class="text-primary hover:underline"
                  >
                    {source_label(mix.source)}
                  </a>
                </div>
                <p :if={mix.status == :failed and mix.error} class="mt-1 text-caption text-coral">
                  {mix.error}
                </p>
              </div>

              <dl class="grid grid-cols-2 gap-3 sm:grid-cols-4 xl:w-[440px]">
                <.mix_fact label="Duração" value={format_clock(mix.duration_ms)} />
                <.mix_fact label="Faixas" value={length(mix.segments)} />
                <.mix_fact label="Na biblioteca" value={library_coverage(mix.segments)} />
                <.mix_fact label="Importado" value={format_date(mix.inserted_at)} />
              </dl>
            </div>
          </article>
        </section>
      </div>
    </.app_shell>
    """
  end

  defp mix_status_label(:downloading), do: "Baixando…"
  defp mix_status_label(:analyzing), do: "Analisando…"
  defp mix_status_label(:ready), do: "Pronto"
  defp mix_status_label(:failed), do: "Falhou"

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp mix_fact(assigns) do
    ~H"""
    <div>
      <dt class="text-caption text-ink-muted">{@label}</dt>
      <dd class="mt-0.5 font-mono text-body-sm text-ink-secondary">{@value}</dd>
    </div>
    """
  end

  defp source_label("youtube"), do: "Abrir no YouTube"
  defp source_label("soundcloud"), do: "Abrir no SoundCloud"
  defp source_label(_), do: "Abrir gravação original"

  defp library_coverage([]), do: "—"

  defp library_coverage(segments) do
    matched = Enum.count(segments, & &1.matched_track_id)
    "#{round(matched / length(segments) * 100)}%"
  end

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_clock(nil), do: "—"

  defp format_clock(ms) do
    total = div(ms, 1000)
    h = div(total, 3600)
    m = total |> div(60) |> rem(60)
    s = rem(total, 60)
    if h > 0, do: "#{h}:#{pad(m)}:#{pad(s)}", else: "#{pad(m)}:#{pad(s)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
