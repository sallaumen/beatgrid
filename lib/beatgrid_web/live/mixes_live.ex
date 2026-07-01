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

        {:error, :unsupported_source} ->
          {:noreply,
           assign(socket,
             toast: {:error, "Só aceito links do YouTube ou SoundCloud por enquanto."}
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
        <header class="flex flex-col gap-1">
          <h1 class="text-[22px] font-semibold">Sets online</h1>
          <p class="text-body-sm text-ink-muted">
            Imported online sets for tracklist study, library coverage, and transition research.
          </p>
        </header>

        <p :if={@toast} class="mt-3 text-body-sm text-ink-secondary">{elem(@toast, 1)}</p>

        <form id="mix-import-form" phx-submit="import" class="mt-4 flex gap-2">
          <input
            type="text"
            name="url"
            value={@url}
            placeholder="Cole a URL do set (YouTube ou SoundCloud)…"
            class="min-w-0 flex-1 rounded-md border border-white/10 bg-surface px-3 py-2 text-body-sm"
          />
          <button class="rounded-md border border-primary/40 bg-primary/10 px-3 py-2 text-body-sm font-semibold text-primary hover:bg-primary/20">
            Importar
          </button>
        </form>

        <section class="mt-6 space-y-2">
          <p :if={@mixes == []} class="text-body-sm text-ink-muted">Nenhum set importado ainda.</p>
          <article
            :for={mix <- @mixes}
            class="rounded-lg border border-white/6 bg-surface px-4 py-3 hover:border-white/12"
          >
            <div class="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <.source_badge source={mix.source} />
                  <.link
                    navigate={~p"/sets-online/#{mix.id}"}
                    class="min-w-0 truncate text-body font-semibold text-ink hover:text-primary"
                  >
                    {mix.title || mix.source_url}
                  </.link>
                  <span class="shrink-0 rounded-full border border-white/8 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
                    {mix_status_label(mix.status)}
                  </span>
                </div>
                <p class="mt-1 truncate text-body-sm text-ink-muted">
                  {mix.dj || "Unknown DJ"} · {source_host(mix.source_url)}
                </p>
                <a
                  href={mix.source_url}
                  target="_blank"
                  rel="noopener"
                  class="mt-1 block truncate text-caption text-primary hover:underline"
                >
                  {source_url_label(mix.source_url)}
                </a>
                <p :if={mix.status == :failed and mix.error} class="mt-1 text-caption text-coral">
                  {mix.error}
                </p>
              </div>

              <div class="grid grid-cols-2 gap-2 sm:grid-cols-4 xl:w-[520px]">
                <.mix_fact label="Duration" value={format_clock(mix.duration_ms)} />
                <.mix_fact label="Tracks" value={"#{length(mix.segments)} tracks"} />
                <.mix_fact label="Library" value={"#{library_coverage(mix.segments)}% library"} />
                <.mix_fact label="Imported" value={format_date(mix.inserted_at)} />
              </div>
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
  attr :value, :string, required: true

  defp mix_fact(assigns) do
    ~H"""
    <div class="rounded-lg border border-white/6 bg-base/45 px-3 py-2">
      <p class="text-[10px] font-semibold uppercase tracking-wide text-ink-faint">{@label}</p>
      <p class="mt-0.5 truncate font-mono text-[13px] text-ink-secondary">{@value}</p>
    </div>
    """
  end

  defp source_badge(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-bold",
      @source == "youtube" && "bg-red-500/15 text-red-300",
      @source == "soundcloud" && "bg-orange-500/15 text-orange-300"
    ]}>
      {if @source == "youtube", do: "YT", else: "SC"}
    </span>
    """
  end

  defp library_coverage([]), do: 0

  defp library_coverage(segments) do
    round(Enum.count(segments, & &1.matched_track_id) / length(segments) * 100)
  end

  defp source_host(url) do
    case URI.parse(url || "") do
      %{host: host} when is_binary(host) -> host
      _ -> "unknown source"
    end
  end

  defp source_url_label(url) when is_binary(url) do
    url
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
  end

  defp source_url_label(_), do: "unknown source"

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
