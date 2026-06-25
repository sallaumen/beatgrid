defmodule BeatgridWeb.UI do
  @moduledoc """
  Beatgrid design-system building blocks: token-driven color helpers and the
  small recurring function components (badges, chips, Camelot seal, cover).
  Colors come from the Claude Design handoff (DESIGN_TOKENS.md).
  """
  use Phoenix.Component

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

  @doc "A stable gradient + initials cover placeholder for a track."
  attr :artist, :string, default: nil
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
      class="flex items-center justify-center font-semibold text-white/90 shrink-0"
      style={"width:#{@size}px;height:#{@size}px;border-radius:#{@radius}px;font-size:#{max(round(@size / 3.4), 10)}px;background:linear-gradient(135deg,#{@a},#{@b})"}
    >
      {@initials}
    </div>
    """
  end

  @doc "App shell: left nav rail + main content."
  attr :active, :atom, default: :biblioteca
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
        <.nav_item icon="hero-chart-bar" label="Painel" href="#" active={@active == :painel} />
        <.nav_item icon="hero-check-circle" label="Revisão" href="#" active={@active == :revisao} />
      </nav>
      <main class="min-w-0 flex-1">{render_slot(@inner_block)}</main>
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
