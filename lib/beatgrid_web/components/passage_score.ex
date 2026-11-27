defmodule BeatgridWeb.PassageScore do
  @moduledoc "Presentation for a transition measured from a rehearsal or the program output."
  use BeatgridWeb, :html

  attr :id, :string, required: true
  attr :title, :string, default: "Nota da passagem"

  @doc "Renders the measurement panel and its persistent announcement target."
  def result(assigns) do
    ~H"""
    <div id={@id} phx-update="ignore" class="@container">
      <section
        hidden
        data-score-panel
        aria-labelledby={"#{@id}-title"}
        class="mt-3 border-y border-white/10 py-3"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <h3 id={"#{@id}-title"} class="text-body-lg font-semibold" data-score-title>{@title}</h3>
          <p data-score-total hidden aria-hidden="true" class="flex items-baseline gap-1 font-mono">
            <span data-score-number class="text-title font-semibold leading-none tabular-nums"></span>
            <span data-score-scale class="text-body text-ink-muted">/100</span>
          </p>
        </div>
        <p data-score-summary class="mt-1 text-body text-ink-secondary"></p>
        <dl data-score-metrics hidden class="mt-3 grid gap-x-3 gap-y-2 @md:grid-cols-3"></dl>
      </section>
      <p data-score-announce aria-live="polite" aria-atomic="true" class="sr-only"></p>
      <template data-score-template>
        <div class="grid min-w-0 items-baseline gap-x-2 border-t border-white/8 pt-1.5 @2xs:grid-cols-2 @md:block">
          <dt data-reading-label class="text-body-sm font-medium text-ink-muted"></dt>
          <dd class="flex min-w-0 flex-wrap items-baseline gap-x-2 @2xs:justify-end @md:justify-start">
            <span data-reading-value class="font-mono text-body tabular-nums"></span>
            <span
              data-reading-state
              class="text-body-sm text-ink-muted data-[state=good]:text-green data-[state=watch]:text-amber data-[state=poor]:text-coral-soft"
            ></span>
          </dd>
        </div>
      </template>
    </div>
    """
  end
end
