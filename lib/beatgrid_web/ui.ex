defmodule BeatgridWeb.UI do
  @moduledoc """
  Beatgrid design-system building blocks: token-driven color helpers and the
  small recurring function components (badges, chips, Camelot seal, cover).
  Colors come from the Claude Design handoff (DESIGN_TOKENS.md).
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @folder_colors %{
    "mpb" => "#8b7bf0",
    "forro" => "#ffb020",
    "forro_classico" => "#e08e00",
    "forro_roots" => "#ff8d97",
    "forro_in_the_light" => "#2d9cff",
    "forro_psicodelico" => "#5ad1a0",
    "forro_mpb" => "#c08bf0"
  }

  @folder_labels %{
    "mpb" => "MPB",
    "forro" => "Forró",
    "forro_classico" => "Forró Clássico",
    "forro_roots" => "Forró Roots",
    "forro_in_the_light" => "Forró In The Light",
    "forro_psicodelico" => "Forró Psicodélico",
    "forro_mpb" => "Forró MPB"
  }

  @cover_palette ~w(#6c5ce7 #8b7bf0 #ffb020 #e08e00 #5ad1a0 #2d9cff #ff8d97 #c08bf0)

  @doc "Hex color for a genre folder key."
  def folder_color(key), do: Map.get(@folder_colors, key, "#9498a6")

  @doc "Human label for a genre folder key."
  def folder_label(nil), do: "—"
  def folder_label(key), do: Map.get(@folder_labels, key, key)

  @doc "Album-art URL for a track (from its Soundcharts song), or nil."
  def cover_src(%{soundcharts_song: %{image_url: url}}) when is_binary(url) and url != "", do: url
  def cover_src(_track), do: nil

  @doc "Hex color for a rating 0–10."
  def rating_color(n) when is_integer(n) and n >= 9, do: "#8b7bf0"
  def rating_color(n) when is_integer(n) and n >= 7, do: "#5ad1a0"
  def rating_color(n) when is_integer(n) and n >= 5, do: "#ffb020"
  def rating_color(n) when is_integer(n) and n >= 0, do: "#ff5d6c"
  def rating_color(_), do: "#5f636f"

  @doc "Hex color for a Camelot code (major B = amber, minor A = amber-deep)."
  def camelot_color(code) when is_binary(code) do
    if String.ends_with?(code, "B"), do: "#ffb020", else: "#e08e00"
  end

  def camelot_color(_), do: "#5f636f"

  @doc "Hex color for a match-confidence level."
  def confidence_color(:high), do: "#5ad1a0"
  def confidence_color(:medium), do: "#ffb020"
  def confidence_color(:low), do: "#ff5d6c"
  def confidence_color(_), do: "#7d818c"

  def confidence_label(:high), do: "ALTA"
  def confidence_label(:medium), do: "MÉDIA"
  def confidence_label(:low), do: "BAIXA"
  def confidence_label(_), do: "SEM MATCH"

  @doc """
  Track cover: the album art (`src`) when available, falling back to a stable
  gradient + initials placeholder (also shown if the image fails to load).
  """
  attr :artist, :string, default: nil
  attr :src, :string, default: nil
  attr :size, :integer, default: 38

  def cover(assigns) do
    {a, b} = cover_gradient(assigns.artist)

    assigns =
      assign(assigns,
        a: a,
        b: b,
        initials: initials(assigns.artist),
        radius: if(assigns.size > 60, do: 14, else: 7)
      )

    ~H"""
    <div
      class="relative flex shrink-0 items-center justify-center overflow-hidden font-semibold text-white/90"
      style={"width:#{@size}px;height:#{@size}px;border-radius:#{@radius}px;font-size:#{max(round(@size / 3.4), 10)}px;background:linear-gradient(135deg,#{@a},#{@b})"}
    >
      {@initials}
      <img
        :if={@src}
        src={@src}
        loading="lazy"
        onerror="this.remove()"
        class="absolute inset-0 h-full w-full object-cover"
      />
    </div>
    """
  end

  @doc """
  A round ▶ button that plays a track in the global player (`#player-audio`).
  `preview` jumps to the backend-configured offset; otherwise it starts at 0.
  """
  attr :src, :string, required: true, doc: "the /audio/:id URL"
  attr :track_id, :string, required: true, doc: "track id, for the now-playing lookup"
  attr :preview, :boolean, default: false
  attr :size, :integer, default: 28
  attr :class, :string, default: nil

  def play_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        JS.dispatch("beatgrid:play",
          to: "#player-audio",
          detail: %{src: @src, id: @track_id, preview: @preview}
        )
      }
      class={[
        "flex shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary hover:bg-primary/25",
        @class
      ]}
      style={"width:#{@size}px;height:#{@size}px;font-size:#{max(round(@size / 2.6), 10)}px"}
      title="Tocar"
    >
      ▶
    </button>
    """
  end

  @doc "App shell: left nav rail + main content + the sticky global player."
  attr :active, :atom, default: :biblioteca
  attr :socket, Phoenix.LiveView.Socket, required: true
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-base text-ink">
      <nav class="flex w-[60px] shrink-0 flex-col items-center gap-2 border-r border-white/6 bg-rail py-4">
        <div
          class="mb-3 size-9 rounded-[10px]"
          style="background:linear-gradient(145deg,#6c5ce7,#8b7bf0);box-shadow:0 6px 18px rgba(108,92,231,.45)"
        />
        <.nav_item
          icon="hero-musical-note"
          label="Biblioteca"
          href="/"
          active={@active == :biblioteca}
        />
        <.nav_item icon="hero-chart-bar" label="Painel" href="/painel" active={@active == :painel} />
        <.nav_item
          icon="hero-check-circle"
          label="Revisão"
          href="/revisao"
          active={@active == :revisao}
        />
        <.nav_item icon="hero-queue-list" label="Sets" href="/set" active={@active == :sets} />
      </nav>
      <main class="min-w-0 flex-1 pb-20">{render_slot(@inner_block)}</main>
      {live_render(@socket, BeatgridWeb.PlayerLive, id: "player", sticky: true)}
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      title={@label}
      class={[
        "flex size-10 items-center justify-center rounded-md transition-colors",
        @active && "bg-primary/15 text-primary",
        !@active && "text-ink-muted hover:text-ink hover:bg-white/5"
      ]}
    >
      <span class={[@icon, "size-5"]} />
    </a>
    """
  end

  @doc "Genre-folder badge."
  attr :folder, :string, required: true

  def folder_badge(assigns) do
    ~H"""
    <span
      class="bg-folder-badge inline-flex items-center rounded-sm px-2 py-[2px] text-[10px] font-semibold"
      style={"--c:#{folder_color(@folder)}"}
    >
      {folder_label(@folder)}
    </span>
    """
  end

  @doc "Match-confidence chip."
  attr :level, :atom, default: nil

  def confidence_chip(assigns) do
    ~H"""
    <span
      class="bg-token-chip inline-flex items-center rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
      style={"--c:#{confidence_color(@level)}"}
    >
      {confidence_label(@level)}
    </span>
    """
  end

  @doc "Camelot seal (mono pill)."
  attr :value, :string, default: nil

  def camelot_seal(assigns) do
    ~H"""
    <span
      :if={@value}
      class="bg-token-chip inline-flex items-center justify-center rounded-full font-mono text-[11px] font-semibold"
      style={"--c:#{camelot_color(@value)};min-width:30px;height:21px;padding:0 6px"}
    >
      {@value}
    </span>
    <span :if={!@value} class="text-ink-faint text-[11px]">—</span>
    """
  end

  @doc "Interactive 0–10 rating control (emits `set_rating` with `n`)."
  attr :value, :integer, default: nil

  def rating_control(assigns) do
    ~H"""
    <div class="flex gap-1">
      <button
        :for={n <- 0..10}
        type="button"
        phx-click="set_rating"
        phx-value-n={n}
        class="flex-1 rounded-md py-[7px] font-mono text-[12px] font-semibold transition-colors"
        style={rating_cell_style(n, @value)}
      >
        {n}
      </button>
    </div>
    """
  end

  defp rating_cell_style(n, value) when is_integer(value) and n <= value,
    do: "background:#{rating_color(value)};color:#0b0c10"

  defp rating_cell_style(_n, _value),
    do: "background:#15171f;color:#9498a6;border:1px solid rgba(255,255,255,.07)"

  @doc "Compact rating badge (table)."
  attr :value, :integer, default: nil

  def rating_badge(assigns) do
    ~H"""
    <span
      :if={is_integer(@value)}
      class="bg-token-chip inline-flex items-center justify-center rounded-sm font-mono text-[12px] font-semibold"
      style={"--c:#{rating_color(@value)};width:28px;height:22px"}
    >
      {@value}
    </span>
    <span :if={!is_integer(@value)} class="text-ink-faint text-[12px]">–</span>
    """
  end

  @doc "Dashboard KPI card (label + big mono value + optional sub)."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :sub, :string, default: nil
  attr :color, :string, default: "#eef0f5"
  attr :alert, :boolean, default: false

  def kpi_card(assigns) do
    ~H"""
    <div class={[
      "rounded-xl bg-surface px-[15px] py-[13px]",
      @alert && "border border-coral/25",
      !@alert && "border border-white/8"
    ]}>
      <p class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">{@label}</p>
      <p class="mt-1 font-mono text-[25px] font-semibold leading-none" style={"color:#{@color}"}>
        {@value}
      </p>
      <p :if={@sub} class="mt-1 text-[10.5px] text-ink-faint">{@sub}</p>
    </div>
    """
  end

  @doc """
  Review card for one suggestion (a rename or an AI classification). Presentational:
  the LiveView maps a suggestion to these attrs and handles the `toggle_select`/
  `reject`/`edit_start`/`edit_save`/`edit_cancel` events (each carries `id` + `type`).

  Selection (`selected`) is ephemeral UI state owned by the LiveView — ticking the
  checkbox never mutates the row, so the list never reorders mid-review. Only the
  "Aplicar" action writes to disk.
  """
  attr :id, :string, required: true
  attr :type, :atom, required: true, doc: ":rename | :classification"
  attr :status, :atom, required: true, doc: ":pending | :rejected | :applied …"
  attr :selected, :boolean, default: false, doc: "checkbox state (queued to apply)"
  attr :selectable, :boolean, default: true, doc: "false hides the checkbox (e.g. Auditoria)"
  attr :editing, :boolean, default: false
  attr :artist, :string, default: nil
  attr :title, :string, default: nil
  attr :from, :string, default: nil, doc: "rename: old filename (struck)"
  attr :to, :string, default: nil, doc: "rename: new filename; classification: target folder key"

  attr :from_folder, :string,
    default: nil,
    doc: "classification: current folder key (nil = inbox)"

  attr :confidence_level, :atom, default: nil
  attr :rationale, :string, default: nil, doc: "classification: AI justification"
  attr :audit, :string, default: nil, doc: "rename: audit flag text"
  attr :folders, :list, default: [], doc: "classification: folder options for the edit picker"
  attr :audio_src, :string, default: nil, doc: "URL to preview the track (▶ skips to 20s)"
  attr :cover_src, :string, default: nil, doc: "album art URL"
  slot :extra, doc: "optional extra action buttons (e.g. audit-tab actions)"

  def suggestion_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex items-start gap-3 rounded-xl px-[14px] py-[13px]",
        suggestion_card_class(@selected, @status)
      ]}
    >
      <.cover src={@cover_src} artist={@artist} size={42} />
      <button
        :if={@audio_src}
        type="button"
        phx-click={JS.dispatch("beatgrid:play", to: "#review-player", detail: %{src: @audio_src})}
        class="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/15 text-[11px] text-primary hover:bg-primary/25"
        title="Tocar (a partir dos 20s)"
      >
        ▶
      </button>
      <div class="min-w-0 flex-1">
        <p class="truncate text-body font-medium">{@title}</p>
        <p :if={@artist} class="text-ink-muted truncate text-caption">{@artist}</p>

        <div :if={!@editing} class="mt-1.5 flex items-center gap-2 text-[12px]">
          <%= if @type == :classification do %>
            <.folder_badge :if={@from_folder} folder={@from_folder} />
            <span :if={!@from_folder} class="text-ink-faint">Inbox</span>
            <span class="text-green">→</span>
            <.folder_badge folder={@to} />
          <% else %>
            <span class="text-coral truncate font-mono line-through">{@from}</span>
            <span class="text-green">→</span>
            <span class="text-ink truncate font-mono">{@to}</span>
          <% end %>
        </div>

        <form
          :if={@editing}
          id={"edit-#{@id}"}
          phx-submit="edit_save"
          class="mt-1.5 flex items-center gap-2"
        >
          <input type="hidden" name="sid" value={@id} />
          <input type="hidden" name="type" value={@type} />
          <select
            :if={@type == :classification}
            name="value"
            class="rounded-md border border-white/8 bg-input px-2 py-1 text-[12px]"
          >
            <option :for={f <- @folders} value={f.key} selected={f.key == @to}>
              {f.display_name}
            </option>
          </select>
          <input
            :if={@type != :classification}
            name="value"
            value={@to}
            class="flex-1 rounded-md border border-white/8 bg-input px-2 py-1 font-mono text-[12px] focus:border-primary/50 focus:outline-none"
          />
          <button class="rounded-md bg-primary px-2.5 py-1 text-[12px] font-semibold text-white">
            Salvar
          </button>
          <button
            type="button"
            phx-click="edit_cancel"
            class="text-ink-muted hover:text-ink text-[12px]"
          >
            Cancelar
          </button>
        </form>

        <div class="mt-1.5 flex items-center gap-2">
          <.confidence_chip level={@confidence_level} />
          <span
            :if={@audit}
            class="bg-token-chip inline-flex items-center rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
            style="--c:#ffb020"
          >
            ⚠ {@audit}
          </span>
        </div>

        <div
          :if={@rationale}
          class="text-ink-muted mt-2 rounded-r-[7px] border-l-2 border-primary/60 bg-[#0d0e14] px-2.5 py-1.5 text-[12px]"
        >
          <span class="font-semibold text-primary">IA:</span> {@rationale}
        </div>

        <div :if={@extra != []} class="mt-2 flex flex-wrap gap-1.5">
          {render_slot(@extra)}
        </div>
      </div>

      <div class="flex w-[112px] shrink-0 flex-col gap-1.5">
        <button
          :if={@selectable and @status != :rejected}
          type="button"
          phx-click="toggle_select"
          phx-value-id={@id}
          aria-pressed={to_string(@selected)}
          class={[
            "flex items-center justify-center gap-1.5 rounded-md px-2 py-1.5 text-[12px] font-semibold transition-colors",
            select_btn_class(@selected)
          ]}
        >
          <span class={[
            "flex size-4 items-center justify-center rounded-[4px] border text-[10px] leading-none",
            checkbox_class(@selected)
          ]}>
            <span :if={@selected}>✓</span>
          </span>
          {if @selected, do: "Marcada", else: "Marcar"}
        </button>
        <span
          :if={@status == :rejected}
          class="rounded-md bg-coral/10 px-2 py-1.5 text-center text-[11px] font-semibold text-coral"
        >
          Rejeitada
        </span>
        <div class="flex gap-1.5">
          <button
            phx-click="edit_start"
            phx-value-id={@id}
            phx-value-type={@type}
            class={[
              "flex-1 rounded-md py-1.5 text-[12px] transition-colors",
              edit_btn_class(@editing)
            ]}
          >
            Editar
          </button>
          <button
            phx-click="reject"
            phx-value-id={@id}
            phx-value-type={@type}
            class={["size-[30px] rounded-md text-[13px] transition-colors", reject_btn_class(@status)]}
          >
            ✕
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp suggestion_card_class(_selected, :rejected),
    do: "border border-coral/35 bg-coral/5 opacity-60"

  defp suggestion_card_class(true, _status), do: "border border-green/40 bg-green/5"
  defp suggestion_card_class(false, _status), do: "border border-white/8 bg-surface"

  defp select_btn_class(true), do: "bg-green text-[#0b0c10]"

  defp select_btn_class(false),
    do: "bg-green/12 text-green border border-green/30 hover:bg-green/20"

  defp checkbox_class(true), do: "border-[#0b0c10] bg-[#0b0c10] text-green"
  defp checkbox_class(false), do: "border-green/45"

  defp edit_btn_class(true), do: "border border-primary/50 text-primary"
  defp edit_btn_class(false), do: "bg-input text-ink-muted hover:text-ink"

  defp reject_btn_class(:rejected), do: "bg-coral text-white"
  defp reject_btn_class(_), do: "bg-coral/10 text-coral hover:bg-coral/20"

  defp initials(nil), do: "♪"
  defp initials(""), do: "♪"

  defp initials(artist) do
    artist
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp cover_gradient(seed) do
    hash = :erlang.phash2(seed || "♪", length(@cover_palette))
    a = Enum.at(@cover_palette, hash)
    b = Enum.at(@cover_palette, rem(hash + 3, length(@cover_palette)))
    {a, b}
  end
end
