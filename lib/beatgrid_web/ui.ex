defmodule BeatgridWeb.UI do
  @moduledoc """
  Beatgrid design-system building blocks: token-driven color helpers and the
  small recurring function components (badges, chips, Camelot seal, cover).
  Colors come from the Claude Design handoff (DESIGN_TOKENS.md).
  """
  use Phoenix.Component

  alias Beatgrid.Library.GenreFolders
  alias Beatgrid.Library.Marker
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

  @doc """
  Hex color for a genre folder key. Seeded keys hit the hardcoded fast path;
  dynamic (user-created) folders fall back to their stored `color` (gray if none).
  """
  def folder_color(key), do: @folder_colors[key] || db_color(key)

  @doc """
  Human label for a genre folder key. Seeded keys hit the hardcoded fast path;
  dynamic folders fall back to their `display_name` (the key itself if not found).
  """
  def folder_label(nil), do: "—"
  def folder_label(key), do: @folder_labels[key] || db_label(key)

  defp db_color(key) do
    case GenreFolders.get_by_key(key) do
      %{color: color} when is_binary(color) and color != "" -> color
      _ -> "#9498a6"
    end
  end

  defp db_label(key) do
    case GenreFolders.get_by_key(key) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> key
    end
  end

  @doc "Album-art URL for a track — only when the match is trusted (art) and not low-confidence."
  def cover_src(%{
        soundcharts_song: %{image_url: url},
        sc_art_trusted: trusted,
        sc_match_confidence: conf
      })
      when is_binary(url) and url != "" and trusted != false and conf != :low,
      do: url

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

  @doc "Integrated loudness for display, e.g. -14.2 LUFS (an em dash when unmeasured)."
  def format_lufs(nil), do: "—"
  def format_lufs(lufs), do: "#{Float.round(lufs, 1)} LUFS"

  @doc "Suggested gain with an explicit sign, e.g. +2.1 dB or -3.0 dB (em dash when unmeasured)."
  def format_gain(nil), do: "—"

  def format_gain(gain) do
    case Float.round(gain, 1) do
      r when r > 0 -> "+#{r} dB"
      r when r == 0.0 -> "0.0 dB"
      r -> "#{r} dB"
    end
  end

  @doc "Color for a loudness jump (LU) between consecutive set tracks (bigger = hotter)."
  def loudness_delta_class(delta) when abs(delta) >= 6, do: "text-coral"
  def loudness_delta_class(delta) when abs(delta) >= 3, do: "text-amber"
  def loudness_delta_class(_delta), do: "text-ink-faint"

  @doc "Contagem de views pra exibição (pt-BR): 2,3 mi · 12 mil · 950 · — quando nil."
  def format_views(nil), do: "—"
  def format_views(v) when v >= 1_000_000, do: "#{br(Float.round(v / 1_000_000, 1))} mi"
  def format_views(v) when v >= 1_000, do: "#{div(v, 1_000)} mil"
  def format_views(v), do: Integer.to_string(v)

  defp br(f), do: f |> :erlang.float_to_binary(decimals: 1) |> String.replace(".", ",")

  @doc "Idade da publicação no YouTube em texto (há N anos · este ano · — quando nil)."
  def format_age(nil), do: "—"

  def format_age(%Date{} = date) do
    case div(Date.diff(Date.utc_today(), date), 365) do
      y when y >= 1 -> "há #{y} #{if y == 1, do: "ano", else: "anos"}"
      _ -> "este ano"
    end
  end

  attr :track, :map, required: true
  attr :interactive, :boolean, default: false

  @doc """
  Selo Ouro (dourado quando confirmado/popular/manual; âmbar com ? quando candidato).
  Com `interactive`, vira um botão clicável (`toggle_gold`) SEMPRE visível — aceso quando
  Ouro (clique remove/reverte), apagado quando não (clique marca). Sem `interactive` (listas),
  é um selo estático que só aparece quando Ouro.
  """
  def ouro_badge(assigns) do
    {is_gold, reason} = Beatgrid.Gold.effective(assigns.track)
    assigns = assign(assigns, gold?: is_gold, reason: reason)

    ~H"""
    <button
      :if={@interactive}
      type="button"
      phx-click="toggle_gold"
      phx-value-id={@track.id}
      title={if @gold?, do: ouro_tooltip(@reason, @track), else: "Clique para marcar como Ouro"}
      class={[
        "inline-flex shrink-0 items-center gap-0.5 rounded-full px-1.5 py-px text-[10px] font-semibold transition",
        @gold? && @reason == :raro_candidato && "bg-amber/15 text-amber",
        @gold? && @reason != :raro_candidato && "bg-[#f5c518]/20 text-[#f5c518]",
        not @gold? && "bg-white/5 text-ink-faint opacity-50 hover:opacity-100 hover:text-[#f5c518]"
      ]}
    >
      ★<span :if={@gold? && @reason == :raro_candidato}>?</span>
    </button>
    <span
      :if={not @interactive and @gold?}
      class={[
        "inline-flex shrink-0 items-center gap-0.5 rounded-full px-1.5 py-px text-[10px] font-semibold",
        @reason == :raro_candidato && "bg-amber/15 text-amber",
        @reason != :raro_candidato && "bg-[#f5c518]/20 text-[#f5c518]"
      ]}
      title={ouro_tooltip(@reason, @track)}
    >
      ★<span :if={@reason == :raro_candidato}>?</span>
    </span>
    """
  end

  defp ouro_tooltip(:manual, _t), do: "Ouro — marcado por você"
  defp ouro_tooltip(:popular, t), do: "Ouro — clássico (#{format_views(t.youtube_views)} views)"
  defp ouro_tooltip(:raro_confirmado, _t), do: "Ouro — não está no Soundcharts"
  defp ouro_tooltip(:raro_candidato, _t), do: "Ouro? — candidato (palpite)"
  defp ouro_tooltip(_, _t), do: "Ouro"

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

  attr :set_id, :string,
    default: nil,
    doc: "when set, plays in set-mode (auto-advance) from this track"

  attr :playing?, :boolean,
    default: false,
    doc: "true when this is the current track: shows a spinning disc; click toggles play/pause"

  def play_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        if @playing?,
          do: JS.dispatch("beatgrid:toggle", to: "#player-audio"),
          else:
            JS.dispatch("beatgrid:play",
              to: "#player-audio",
              detail: %{src: @src, id: @track_id, preview: @preview, set_id: @set_id}
            )
      }
      class={[
        "flex shrink-0 items-center justify-center rounded-full",
        !@playing? && "bg-primary/15 text-primary hover:bg-primary/25",
        @class
      ]}
      style={"width:#{@size}px;height:#{@size}px;font-size:#{max(round(@size / 2.6), 10)}px"}
      title={if @playing?, do: "Tocar ou pausar", else: "Tocar"}
      aria-label={if @playing?, do: "Tocar ou pausar", else: "Tocar"}
    >
      <.vinyl :if={@playing?} size={@size} />
      <span :if={!@playing?} aria-hidden="true">▶</span>
    </button>
    """
  end

  @doc "Spinning vinyl indicator for the currently-playing track (spin gated by CSS)."
  attr :size, :integer, default: 28

  def vinyl(assigns) do
    ~H"""
    <span
      class="now-playing-disc flex shrink-0 animate-spin items-center justify-center rounded-full"
      style={"width:#{@size}px;height:#{@size}px;background:radial-gradient(circle,#0c0c0f 30%,#3a3a44 33%,#0c0c0f 37%,#3a3a44 46%,#0c0c0f 50%)"}
      aria-hidden="true"
    >
      <span class="block rounded-full bg-primary" style="width:34%;height:34%"></span>
    </span>
    """
  end

  @doc """
  Album cover with a hover-reveal ▶ overlay that plays in the global player.
  The overlay is a sibling button (never wrap it in a navigate link, or the click
  would also navigate — keep it outside any `<.link>`).
  """
  attr :src, :string, default: nil, doc: "cover image URL"
  attr :artist, :string, default: nil
  attr :size, :integer, default: 38
  attr :play_src, :string, required: true, doc: "the /audio/:id URL"
  attr :track_id, :string, required: true
  attr :preview, :boolean, default: true

  attr :playing?, :boolean,
    default: false,
    doc: "true when this is the current track: a persistent spinning disc; click toggles"

  def cover_play(assigns) do
    assigns = assign(assigns, :radius, if(assigns.size > 60, do: 14, else: 7))

    ~H"""
    <div class="group/cover relative shrink-0" style={"width:#{@size}px;height:#{@size}px"}>
      <.cover src={@src} artist={@artist} size={@size} />
      <button
        type="button"
        phx-click={
          if @playing?,
            do: JS.dispatch("beatgrid:toggle", to: "#player-audio"),
            else:
              JS.dispatch("beatgrid:play",
                to: "#player-audio",
                detail: %{src: @play_src, id: @track_id, preview: @preview}
              )
        }
        class={[
          "absolute inset-0 items-center justify-center text-[12px] text-white",
          @playing? && "flex bg-black/40",
          !@playing? && "hidden bg-black/55 group-hover/cover:flex"
        ]}
        style={"border-radius:#{@radius}px"}
        title={if @playing?, do: "Tocar ou pausar", else: "Tocar"}
        aria-label={if @playing?, do: "Tocar ou pausar", else: "Tocar"}
      >
        <.vinyl :if={@playing?} size={max(trunc(@size * 0.5), 16)} />
        <span :if={!@playing?} aria-hidden="true">▶</span>
      </button>
    </div>
    """
  end

  @doc """
  Manageable list of a track's cue-point markers. Display-only: the host LiveView
  handles `rename_marker` (form submit, Enter saves) and `remove_marker` (✕). The
  time button either seeks the live player (`seekable: true`) or plays this track
  from that marker. Shared by the player popover and the track page.
  """
  attr :markers, :list, required: true, doc: ~s(list of %{"ms" => int, "label" => str | nil})
  attr :track_id, :string, required: true
  attr :play_src, :string, required: true, doc: "the /audio/:id URL (for play-from-marker)"

  attr :seekable, :boolean,
    default: false,
    doc: "true → time button seeks the live player; false → plays this track from the marker"

  attr :id_prefix, :string,
    default: "marker",
    doc:
      "scopes the per-row form ids so two instances (player popover + track page) don't collide"

  attr :empty_hint, :string, default: "Nenhum marcador ainda — toque a faixa e use ＋ para marcar."

  def marker_list(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <p :if={@markers == []} class="text-caption text-ink-faint">{@empty_hint}</p>
      <div
        :for={m <- @markers}
        class="flex items-center gap-2 rounded-md border border-l-2 border-white/8 bg-white/3 px-2 py-1"
        style={"border-left-color:#{Marker.color(m)}"}
      >
        <button
          type="button"
          phx-click={
            if @seekable,
              do: JS.dispatch("beatgrid:seek", to: "#player-audio", detail: %{ms: m["ms"]}),
              else:
                JS.dispatch("beatgrid:play",
                  to: "#player-audio",
                  detail: %{src: @play_src, id: @track_id, at_ms: m["ms"]}
                )
          }
          class="shrink-0 font-mono text-[11px] hover:underline"
          style={"color:#{Marker.color(m)}"}
          title="Pular para este ponto"
        >
          {format_ms(m["ms"])}
        </button>
        <div class="flex shrink-0 overflow-hidden rounded border border-white/10">
          <button
            :for={t <- Marker.types()}
            type="button"
            phx-click="set_marker_type"
            phx-value-ms={m["ms"]}
            phx-value-type={t}
            class={[
              "px-1 text-[9px] font-semibold uppercase leading-none",
              (Marker.type(m) == t && "text-black") || "text-ink-faint hover:text-ink"
            ]}
            style={
              if(Marker.type(m) == t,
                do: "background:#{Marker.color(m)};padding-top:3px;padding-bottom:3px"
              )
            }
            title={marker_type_title(t)}
          >
            {marker_type_abbrev(t)}
          </button>
        </div>
        <form id={"#{@id_prefix}-rename-#{m["ms"]}"} phx-submit="rename_marker" class="min-w-0 flex-1">
          <input type="hidden" name="ms" value={m["ms"]} />
          <input
            type="text"
            name="label"
            value={m["label"]}
            placeholder="nomear (Enter salva)…"
            aria-label={"Nome do marcador em #{format_ms(m["ms"])}"}
            class="w-full rounded bg-transparent px-1 py-0.5 text-[12px] text-ink placeholder:text-ink-faint focus:bg-white/5 focus:outline-none"
          />
        </form>
        <span
          :if={Marker.auto?(m)}
          class="text-ink-faint shrink-0 rounded bg-white/5 px-1 text-[9px] uppercase"
          title="Marcador automático (análise de áudio)"
        >
          auto
        </span>
        <button
          type="button"
          phx-click="remove_marker"
          phx-value-ms={m["ms"]}
          class="text-ink-muted hover:text-coral shrink-0"
          title="Remover marcador"
          aria-label="Remover marcador"
        >
          ✕
        </button>
      </div>
    </div>
    """
  end

  defp marker_type_abbrev("intro"), do: "in"
  defp marker_type_abbrev("outro"), do: "out"
  defp marker_type_abbrev(_cue), do: "cue"

  defp marker_type_title("intro"), do: "Entrada (mix-in)"
  defp marker_type_title("outro"), do: "Saída (mix-out)"
  defp marker_type_title(_cue), do: "Cue genérico"

  @doc "Formats milliseconds as `m:ss` (cue-point display)."
  @spec format_ms(integer() | any()) :: String.t()
  def format_ms(ms) when is_integer(ms) do
    total = div(ms, 1000)
    "#{div(total, 60)}:#{String.pad_leading(Integer.to_string(rem(total, 60)), 2, "0")}"
  end

  def format_ms(_ms), do: "0:00"

  @doc "App shell: left nav rail + main content + the sticky global player."
  attr :active, :atom, default: :biblioteca
  attr :socket, Phoenix.LiveView.Socket, required: true
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-base text-ink">
      <nav
        aria-label="Navegação principal"
        class="flex w-[216px] shrink-0 flex-col gap-5 border-r border-white/6 bg-rail px-3 py-4 transition-[width] duration-200 ease-out nav-collapsed:w-[68px] nav-collapsed:px-2"
      >
        <div class="flex items-center gap-2.5 px-1 nav-collapsed:justify-center nav-collapsed:px-0">
          <div
            class="size-9 shrink-0 rounded-[10px]"
            style="background:linear-gradient(145deg,#6c5ce7,#8b7bf0);box-shadow:0 6px 18px rgba(108,92,231,.45)"
          />
          <span class="flex-1 truncate text-[15px] font-semibold tracking-tight nav-collapsed:hidden">
            Beatgrid
          </span>
          <button
            type="button"
            data-nav-toggle
            aria-label="Recolher menu lateral"
            class="flex size-7 shrink-0 items-center justify-center rounded-md text-ink-faint transition-colors hover:bg-white/5 hover:text-ink nav-collapsed:hidden"
          >
            <span class="hero-chevron-double-left size-4" aria-hidden="true" />
          </button>
        </div>

        <button
          type="button"
          data-nav-toggle
          aria-label="Expandir menu lateral"
          class="mx-auto hidden size-7 items-center justify-center rounded-md text-ink-faint transition-colors hover:bg-white/5 hover:text-ink nav-collapsed:flex"
        >
          <span class="hero-chevron-double-right size-4" aria-hidden="true" />
        </button>

        <div :for={section <- nav_sections()} class="flex flex-col gap-1">
          <p class="px-2 pb-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-ink-faint nav-collapsed:hidden">
            {section.title}
          </p>
          <div
            class="mx-auto my-1 hidden h-px w-7 rounded-full bg-white/8 nav-collapsed:block"
            aria-hidden="true"
          />
          <.nav_item :for={item <- section.items} item={item} active={@active == item.key} />
        </div>
      </nav>
      <main class="min-w-0 flex-1 pb-20">{render_slot(@inner_block)}</main>
      {live_render(@socket, BeatgridWeb.PlayerLive, id: "player", sticky: true)}
    </div>
    """
  end

  # Nav grouped by workflow so the order tells a story: the collection you browse
  # → the curation inbox flow (import → review → de-dup → tag) → system. `key`
  # matches the `active` atom each LiveView passes; `short` is the 3-letter label
  # shown when the rail is collapsed (icon-only was the old, confusing state).
  defp nav_sections do
    [
      %{
        title: "Coleção",
        items: [
          %{
            key: :biblioteca,
            label: "Biblioteca",
            short: "BIB",
            icon: "hero-musical-note",
            href: "/"
          },
          %{key: :sets, label: "Sets", short: "SET", icon: "hero-queue-list", href: "/set"},
          %{key: :painel, label: "Painel", short: "PNL", icon: "hero-chart-bar", href: "/painel"}
        ]
      },
      %{
        title: "Curadoria",
        items: [
          %{
            key: :importados,
            label: "Importados",
            short: "IMP",
            icon: "hero-arrow-down-tray",
            href: "/importados"
          },
          %{
            key: :revisao,
            label: "Revisão",
            short: "REV",
            icon: "hero-check-circle",
            href: "/revisao"
          },
          %{
            key: :dedup,
            label: "Duplicatas",
            short: "DUP",
            icon: "hero-document-duplicate",
            href: "/dedup"
          },
          %{key: :generos, label: "Gêneros", short: "GEN", icon: "hero-tag", href: "/generos"},
          %{
            key: :mixes,
            label: "Sets online",
            short: "MIX",
            icon: "hero-rectangle-stack",
            href: "/sets-online"
          }
        ]
      },
      %{
        title: "Sistema",
        items: [
          %{key: :jobs, label: "Jobs", short: "JOB", icon: "hero-arrow-path", href: "/jobs"}
        ]
      }
    ]
  end

  attr :item, :map, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@item.href}
      title={@item.label}
      aria-label={@item.label}
      aria-current={@active && "page"}
      class={[
        "relative flex items-center gap-3 rounded-lg px-2.5 py-2 transition-colors",
        "nav-collapsed:flex-col nav-collapsed:gap-1 nav-collapsed:px-1 nav-collapsed:py-2.5",
        @active && "bg-primary/12 text-primary",
        !@active && "text-ink-muted hover:bg-white/5 hover:text-ink"
      ]}
    >
      <span
        :if={@active}
        class="absolute left-0 top-1/2 h-5 w-[3px] -translate-y-1/2 rounded-r-full bg-primary nav-collapsed:hidden"
        aria-hidden="true"
      />
      <span class={[@item.icon, "size-5 shrink-0"]} aria-hidden="true" />
      <span class="truncate text-[13px] font-medium tracking-tight nav-collapsed:hidden">
        {@item.label}
      </span>
      <span class="hidden text-[9px] font-semibold uppercase tracking-wider nav-collapsed:block">
        {@item.short}
      </span>
    </.link>
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

  # ── Mixing console (REC SET) ───────────────────────────────────────────────

  @dimension_colors %{
    style: "#8b7bf0",
    harmony: "#2d9cff",
    intensity: "#5ad1a0",
    bpm: "#ffb020",
    rating: "#ff5d6c"
  }

  @doc "Hex color for a scoring dimension (matches the fader colors)."
  def dimension_color(key), do: Map.get(@dimension_colors, key, "#9498a6")

  @doc """
  A vertical weight fader — one channel of the REC SET mixing console. The native
  range is rotated (`writing-mode: vertical-lr; direction: rtl`) so dragging up =
  more weight; a colocated `.Fader` hook pushes `set_weight` on slider *release*
  (the native `change` event). The recessed track shows a fill in the dimension's
  color so the channel reads at a glance.
  """
  attr :dim, :atom, required: true, doc: ":style | :harmony | :intensity | :bpm | :rating"
  attr :label, :string, required: true
  attr :value, :integer, required: true

  attr :nonce, :integer,
    default: 0,
    doc: "bump to force the native range to re-mount (e.g. on Resetar)"

  def fader(assigns) do
    assigns =
      assign(assigns,
        color: dimension_color(assigns.dim),
        dim_str: Atom.to_string(assigns.dim),
        id: "fader-#{assigns.nonce}-#{assigns.dim}",
        fill: max(min(assigns.value, 100), 0)
      )

    ~H"""
    <div class="flex w-12 shrink-0 flex-col items-center gap-2">
      <span class="font-mono text-[13px] font-semibold tabular-nums" style={"color:#{@color}"}>
        {@value}
      </span>
      <div
        class="relative flex h-36 w-7 items-end justify-center overflow-hidden rounded-md border border-white/8 bg-deep"
        style="box-shadow:inset 0 1px 3px rgba(0,0,0,.6)"
      >
        <div
          class="pointer-events-none absolute inset-x-0 bottom-0 rounded-b-md"
          style={"height:#{@fill}%;background:linear-gradient(180deg,color-mix(in srgb,#{@color} 70%,transparent),color-mix(in srgb,#{@color} 22%,transparent))"}
        >
        </div>
        <span
          class="pointer-events-none absolute inset-x-1 top-1/2 h-px -translate-y-1/2 bg-white/8"
          aria-hidden="true"
        ></span>
        <input
          id={@id}
          type="range"
          min="0"
          max="100"
          step="1"
          value={@value}
          phx-hook=".Fader"
          data-dim={@dim_str}
          data-value={@value}
          aria-label={"Peso: #{@label}"}
          class="relative h-32 w-7 cursor-pointer appearance-none bg-transparent"
          style={"writing-mode:vertical-lr;direction:rtl;accent-color:#{@color}"}
        />
      </div>
      <span class="text-[10px] font-semibold uppercase tracking-wide text-ink-muted">{@label}</span>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Fader">
      export default {
        mounted() {
          this.el.addEventListener("change", () => {
            this.pushEvent("set_weight", { dim: this.el.dataset.dim, value: this.el.value })
          })
        },
        updated() {
          this.el.value = this.el.dataset.value
        }
      }
    </script>
    """
  end

  @doc """
  Score-composition bar for one candidate: five inline segments whose widths are
  each dimension's contribution (`weight × breakdown[dim]`) normalized to the row
  total, colored by `dimension_color/1`. Reads as "what's driving this match".
  """
  attr :breakdown, :map, required: true
  attr :weights, :map, required: true

  def composition_bar(assigns) do
    assigns = assign(assigns, :segments, composition_segments(assigns.breakdown, assigns.weights))

    ~H"""
    <div class="flex h-1.5 w-full overflow-hidden rounded-full bg-white/6" aria-hidden="true">
      <span
        :for={{dim, pct} <- @segments}
        :if={pct > 0}
        class="h-full first:rounded-l-full last:rounded-r-full"
        style={"width:#{pct}%;background:#{dimension_color(dim)}"}
        title={"#{dimension_label(dim)} #{Float.round(pct, 0) |> trunc()}%"}
      ></span>
    </div>
    """
  end

  @composition_dims [:style, :harmony, :intensity, :bpm, :rating]

  defp composition_segments(breakdown, weights) do
    contributions =
      Map.new(@composition_dims, fn dim ->
        weight = Map.get(weights, dim, 0)
        part = Map.get(breakdown, dim, 0.0) || 0.0
        {dim, weight * part}
      end)

    total = contributions |> Map.values() |> Enum.sum()

    if total > 0 do
      Enum.map(@composition_dims, fn dim ->
        {dim, Map.fetch!(contributions, dim) / total * 100}
      end)
    else
      Enum.map(@composition_dims, fn dim -> {dim, 0.0} end)
    end
  end

  defp dimension_label(:style), do: "Estilo"
  defp dimension_label(:harmony), do: "Tom"
  defp dimension_label(:intensity), do: "Energia"
  defp dimension_label(:bpm), do: "Tempo"
  defp dimension_label(:rating), do: "Nota"

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
  attr :track_id, :string, default: nil, doc: "track id for the global player"
  attr :cover_src, :string, default: nil, doc: "album art URL"
  attr :playing?, :boolean, default: false, doc: "true when this card's track is the current one"
  slot :extra, doc: "optional extra action buttons (e.g. audit-tab actions)"

  def suggestion_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex items-start gap-3 rounded-xl px-[14px] py-[13px]",
        suggestion_card_class(@selected, @status),
        @playing? && "ring-1 ring-primary/50"
      ]}
    >
      <.cover_play
        :if={@audio_src && @track_id}
        src={@cover_src}
        artist={@artist}
        size={42}
        play_src={@audio_src}
        track_id={@track_id}
        preview={true}
        playing?={@playing?}
      />
      <.cover :if={!(@audio_src && @track_id)} src={@cover_src} artist={@artist} size={42} />
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

  attr :key, :atom, required: true

  @doc "Inline warning when an integration isn't configured; renders nothing when it is."
  def integration_gate(assigns) do
    ~H"""
    <span :if={not Beatgrid.Integrations.configured?(@key)} class="text-[11px] text-amber-300/90">
      Configure {Beatgrid.Integrations.missing_env(@key)} no <code>.env</code>
    </span>
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
