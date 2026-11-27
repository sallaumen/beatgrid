defmodule BeatgridWeb.MixesLive do
  @moduledoc "Curadoria: import + study recorded online DJ sets — the index/list."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Mixes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Mixes.subscribe()

    {:ok,
     assign(socket,
       page_title: "Sets gravados",
       mixes: Mixes.list_mixes(),
       url: "",
       query: "",
       toast: nil
     )}
  end

  @impl true
  def handle_event("import", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, socket}
    else
      socket = assign(socket, url: url)

      case Mixes.import_url(url) do
        {:ok, mix} ->
          {:noreply,
           assign(socket,
             mixes: Mixes.list_mixes(),
             url: "",
             toast: %{kind: :ok, message: "Gravação adicionada à fila.", mix_id: mix.id}
           )}

        {:error, :unsupported_source} ->
          {:noreply,
           assign(socket,
             toast: %{
               kind: :error,
               message: "Cole um link do YouTube ou SoundCloud.",
               mix_id: nil
             }
           )}

        {:error, _changeset} ->
          {:noreply, existing_recording_feedback(socket, url)}
      end
    end
  end

  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: query)}

  def handle_event("clear_search", _params, socket), do: {:noreply, assign(socket, query: "")}

  @impl true
  def handle_info({:mix_progress, _payload}, socket) do
    {:noreply, assign(socket, mixes: Mixes.list_mixes())}
  end

  # Exact URL matches are the existing recording, even if the current search hides it.
  defp existing_recording_feedback(socket, url) do
    mixes = Mixes.list_mixes()

    toast =
      case Enum.find(mixes, &(&1.source_url == url)) do
        nil ->
          %{kind: :error, message: "Não foi possível importar esse link.", mix_id: nil}

        mix ->
          %{kind: :ok, message: "Já existe uma gravação para esse link.", mix_id: mix.id}
      end

    assign(socket, mixes: mixes, toast: toast)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible_mixes, search_mixes(assigns.mixes, assigns.query))

    ~H"""
    <.app_shell flash={@flash} active={:mixes} socket={@socket}>
      <header class="border-b border-white/6 bg-rail px-3 py-3 sm:px-6">
        <div class="mx-auto max-w-[1600px]">
          <h1 class="text-[22px] font-semibold">Sets gravados</h1>
        </div>
      </header>
      <div class="@container mx-auto max-w-[1600px] px-3 py-5 sm:px-6">
        <form
          id="mix-import-form"
          phx-submit="import"
          class="rounded-xl border border-white/8 bg-surface p-4"
        >
          <label for="mix-source-url" class="mb-2 block text-body font-semibold text-ink-secondary">
            Link do YouTube ou SoundCloud
          </label>
          <div class="flex flex-col gap-2 sm:flex-row">
            <input
              id="mix-source-url"
              type="url"
              name="url"
              value={@url}
              required
              placeholder="Cole o link da gravação"
              class="min-w-0 flex-1 rounded-md border border-white/10 bg-input px-3 py-2 text-body"
            />
            <button
              phx-disable-with="Importando..."
              class="rounded-md bg-primary-deep px-3 py-2 text-body-sm font-semibold text-white hover:bg-primary-deep/90"
            >
              Importar gravação
            </button>
          </div>
        </form>

        <div
          :if={@toast}
          id="mix-import-feedback"
          class="mt-3 flex flex-wrap items-center justify-between gap-x-3 gap-y-1"
        >
          <p
            role="status"
            class={[
              "min-w-0 text-body",
              if(@toast.kind == :error, do: "text-coral", else: "text-ink-secondary")
            ]}
          >
            {@toast.message}
          </p>
          <.link
            :if={@toast.mix_id}
            id="mix-import-open"
            navigate={~p"/sets-online/#{@toast.mix_id}"}
            class="inline-flex min-h-9 items-center gap-1.5 rounded-md border border-primary/40 bg-primary/10 px-3 py-1.5 text-body font-semibold text-primary hover:bg-primary/20"
          >
            Abrir ficha <span class="hero-chevron-right size-3.5" aria-hidden="true" />
          </.link>
        </div>

        <section id="recorded-mixes" class="mt-6">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-[18px] font-semibold">
              Gravações
              <span class="ml-1 font-mono text-body font-normal text-ink-muted">{length(
                @visible_mixes
              )}/{length(@mixes)}</span>
            </h2>
            <form
              :if={@mixes != []}
              id="mix-search"
              phx-change="search"
              phx-submit="search"
              class="flex min-w-0 items-center gap-2"
            >
              <label for="mix-query" class="sr-only">Buscar gravações por título ou DJ</label>
              <input
                id="mix-query"
                name="query"
                type="search"
                value={@query}
                phx-debounce="150"
                placeholder="Título ou DJ"
                class="w-full min-w-0 rounded-md border border-white/10 bg-input px-3 py-2 text-body sm:w-56"
              />
              <button
                :if={@query != ""}
                type="button"
                phx-click="clear_search"
                class="text-body-sm text-ink-secondary hover:text-ink"
              >Limpar</button>
            </form>
          </div>
          <p :if={@mixes == []} class="mt-3 text-body text-ink-muted">
            Importe uma gravação para conferir as faixas, estudar as transições e salvar recortes na biblioteca.
          </p>
          <p
            :if={@mixes != [] && @visible_mixes == []}
            role="status"
            class="mt-3 text-body text-ink-muted"
          >
            Nenhuma gravação corresponde à busca.
          </p>
          <div :if={@visible_mixes != []} class="mt-3 divide-y divide-white/8 border-y border-white/8">
            <article
              :for={mix <- @visible_mixes}
              id={"recorded-mix-#{mix.id}"}
              class="grid gap-3 py-3 @min-[48rem]:grid-cols-[minmax(0,1fr)_24rem] @min-[48rem]:items-center"
            >
              <div class="min-w-0">
                <.link
                  navigate={~p"/sets-online/#{mix.id}"}
                  class="group flex min-h-9 min-w-0 items-start justify-between gap-3 rounded-xs text-ink hover:text-primary sm:min-h-0"
                >
                  <span class="min-w-0 text-body-lg font-semibold [overflow-wrap:anywhere] group-hover:underline">
                    {mix.title || mix.source_url}
                  </span>
                  <span class="inline-flex shrink-0 items-center gap-1 text-body-sm font-semibold text-primary">
                    Abrir ficha <span class="hero-chevron-right size-3.5" aria-hidden="true" />
                  </span>
                </.link>
                <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-body text-ink-muted">
                  <span class={[
                    "shrink-0 rounded-xs px-2 py-0.5 text-caption font-semibold",
                    mix_status_tone(mix.status)
                  ]}>
                    {mix_status_label(mix.status)}
                  </span>
                  <span :if={mix.audio_deleted_at} class="text-caption text-ink-muted">Áudio apagado</span>
                  <span class="min-w-0 [overflow-wrap:anywhere]">{mix.dj || "DJ desconhecido"}</span>
                  <a
                    href={mix.source_url}
                    target="_blank"
                    rel="noopener"
                    class="inline-flex min-h-7 items-center gap-1 text-ink-muted underline decoration-white/20 hover:text-ink hover:decoration-current"
                    aria-label={"#{source_label(mix.source)}: #{mix.title || mix.source_url} (nova aba)"}
                  >
                    {source_label(mix.source)}
                    <span class="hero-arrow-up-right size-3" aria-hidden="true" />
                  </a>
                </div>
                <p
                  :if={mix.status == :failed and mix.error}
                  class="mt-1 text-body-sm text-coral [overflow-wrap:anywhere]"
                >
                  {mix.error}
                </p>
              </div>

              <dl class="grid grid-cols-2 gap-x-4 gap-y-2 @min-[25rem]:grid-cols-4">
                <.mix_fact label="Duração" value={format_clock(mix.duration_ms)} />
                <.mix_fact label="Faixas" value={length(mix.segments)} />
                <div>
                  <dt class="text-caption text-ink-muted">Na biblioteca</dt>
                  <dd class="mt-0.5 font-mono text-body tabular-nums text-ink-secondary">
                    {library_coverage(mix.segments)}
                  </dd>
                  <div
                    :if={mix.segments != []}
                    aria-hidden="true"
                    class="mt-1 h-1 rounded-full bg-white/8"
                  >
                    <div
                      class="h-full rounded-full bg-primary"
                      style={"width:#{library_coverage(mix.segments)}"}
                    >
                    </div>
                  </div>
                </div>
                <.mix_fact label="Importado" value={format_date(mix.inserted_at)} />
              </dl>
            </article>
          </div>
        </section>
      </div>
    </.app_shell>
    """
  end

  defp search_mixes(mixes, query) do
    query = query |> String.trim() |> String.downcase()

    Enum.filter(mixes, fn mix ->
      [mix.title, mix.dj, mix.source_url]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&String.contains?(String.downcase(&1), query))
    end)
  end

  defp mix_status_tone(:ready), do: "bg-green/10 text-green"
  defp mix_status_tone(:failed), do: "bg-coral/10 text-coral"
  defp mix_status_tone(_), do: "bg-primary/10 text-primary"

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
      <dd class="mt-0.5 font-mono text-body tabular-nums text-ink-secondary">{@value}</dd>
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
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y")

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
