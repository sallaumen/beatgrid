defmodule BeatgridWeb.CoreComponents do
  @moduledoc """
  What survives of the Phoenix generator's component set: the flash toast and
  the heroicon span, plus the two JS transitions `BeatgridWeb.Layouts.flash_group/1`
  drives them with.

  Beatgrid's own building blocks live in `BeatgridWeb.UI`, and screens write
  their own markup against the tokens in `DESIGN.md`. The generated button,
  input, table, list and header components were deleted once the app had
  outgrown all of them — they were the last place a second type scale and the
  light-theme surface survived.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "pointer-events-auto flex cursor-pointer items-start gap-2.5 rounded-lg border",
        "bg-surface px-3 py-2.5 shadow-[var(--shadow-elevated)]",
        @kind == :info && "border-green/30",
        @kind == :error && "border-coral/35"
      ]}
      {@rest}
    >
      <.icon
        name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-information-circle"}
        class={["mt-px size-4 shrink-0", (@kind == :error && "text-coral") || "text-green"]}
      />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="text-body font-semibold text-ink">{@title}</p>
        <p class="text-body text-ink-secondary">{msg}</p>
      </div>
      <button
        type="button"
        class="text-ink-faint hover:text-ink shrink-0 transition-colors"
        aria-label="Fechar"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini. By default, the
  outline style is used, but solid and mini may be applied by using the `-solid`
  and `-mini` suffix.

  You can customize the size and colors of the icons by setting width, height,
  and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
