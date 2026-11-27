defmodule BeatgridWeb.RecommendationComponents do
  @moduledoc "Shared decision and history presentation for repertoire gap and track match suggestions."
  use BeatgridWeb, :html

  alias Beatgrid.Repertoire

  attr :rec, :map, required: true

  def rec_row(assigns) do
    ~H"""
    <article
      id={"recommendation-#{@rec.id}"}
      class="flex min-w-0 flex-col rounded-lg border border-white/8 bg-base px-3 py-2.5"
    >
      <div class="flex flex-1 items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <p class="text-body font-medium [overflow-wrap:anywhere]">
            {@rec.artist} <span class="text-ink-faint">—</span> {@rec.song}
          </p>
          <p :if={@rec.reason} class="mt-1 text-body-sm text-ink-secondary [overflow-wrap:anywhere]">
            {@rec.reason}
          </p>
        </div>
        <span
          :if={@rec.status == :imported}
          class="bg-token-chip inline-flex shrink-0 items-center gap-1 rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
          style="--c:var(--color-green)"
        >
          <.icon name="hero-check-mini" class="size-3" /> Importada
        </span>
      </div>
      <.rec_actions :if={@rec.status != :imported} rec={@rec} primary?={true} />
      <details :if={@rec.status == :imported} id={"recommendation-options-#{@rec.id}"} class="mt-2">
        <summary
          aria-label={"Opções da sugestão #{@rec.song}"}
          class="w-fit cursor-pointer rounded-xs py-1 text-body-sm text-ink-muted hover:text-ink"
        >
          Opções da sugestão
        </summary>
        <.rec_actions rec={@rec} primary?={false} />
      </details>
    </article>
    """
  end

  attr :rec, :map, required: true
  attr :primary?, :boolean, required: true

  defp rec_actions(assigns) do
    ~H"""
    <div class="mt-2 flex flex-wrap items-center gap-1.5" data-recommendation-actions>
      <.link
        navigate={~p"/importados?recomendacao=#{@rec.id}"}
        aria-label={"Conferir versões de #{@rec.song}"}
        class={[
          "inline-flex min-h-8 items-center gap-1 rounded-md border px-2.5 py-1.5 text-body-sm",
          if(@primary?,
            do: "border-primary/35 bg-primary/10 font-semibold text-primary-soft hover:bg-primary/15",
            else: "border-white/10 bg-input text-ink-secondary hover:text-ink"
          )
        ]}
      >
        Conferir versões <.icon name="hero-arrow-right-mini" class="size-4" />
      </.link>
      <a
        href={Repertoire.youtube_search_url(@rec)}
        target="_blank"
        rel="noopener"
        aria-label={"Buscar no YouTube: #{@rec.song} (nova aba)"}
        class="inline-flex min-h-8 items-center gap-1 rounded-md border border-white/10 bg-input px-2.5 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
      >
        Buscar no YouTube <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
      </a>
      <button
        type="button"
        phx-click="dismiss_rec"
        phx-value-id={@rec.id}
        aria-label={"Dispensar #{@rec.song}"}
        class="ml-auto min-h-8 rounded-md px-2.5 py-1.5 text-body-sm text-ink-muted hover:text-coral"
      >
        Dispensar
      </button>
    </div>
    """
  end
end
