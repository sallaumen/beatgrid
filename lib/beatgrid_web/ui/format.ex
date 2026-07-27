defmodule BeatgridWeb.UI.Format do
  @moduledoc """
  Pure display formatters: token colors, labels and value formatting shared by
  every screen. No markup here — function components live in `BeatgridWeb.UI`.
  Colors come from the Claude Design handoff (DESIGN_TOKENS.md).
  """

  alias Beatgrid.Library.GenreFolders

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

  # Per-row hot path (badges in the library / rec-set / console lists): reads the
  # cached folder map, never the DB.
  defp db_color(key) do
    case GenreFolders.by_key()[key] do
      %{color: color} when is_binary(color) and color != "" -> color
      _ -> "#9498a6"
    end
  end

  defp db_label(key) do
    case GenreFolders.by_key()[key] do
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

  @doc "Formats milliseconds as `m:ss` (cue-point display)."
  @spec format_ms(integer() | any()) :: String.t()
  def format_ms(ms) when is_integer(ms) do
    total = div(ms, 1000)
    "#{div(total, 60)}:#{String.pad_leading(Integer.to_string(rem(total, 60)), 2, "0")}"
  end

  def format_ms(_ms), do: "0:00"

  @doc """
  Effective BPM for display — manual override, then Soundcharts, then detected
  (the `Library.effective/1` precedence; requires `:soundcharts_song` preloaded).
  Every screen must render THIS, never a hand-rolled fallback chain: the REC SET
  once skipped the manual clause and showed stale values for corrected tracks.
  """
  @spec effective_bpm(Beatgrid.Library.Track.t() | any()) :: integer() | String.t()
  def effective_bpm(%Beatgrid.Library.Track{} = track) do
    case Beatgrid.Library.effective(track).bpm do
      bpm when is_number(bpm) -> round(bpm)
      _missing -> "—"
    end
  end

  def effective_bpm(_track), do: "—"

  @doc "Effective Camelot key for display — same precedence as `effective_bpm/1`."
  @spec effective_camelot(Beatgrid.Library.Track.t() | any()) :: String.t() | nil
  def effective_camelot(%Beatgrid.Library.Track{} = track),
    do: Beatgrid.Library.effective(track).camelot

  def effective_camelot(_track), do: nil

  @doc "1–2 uppercase initials from an artist name (♪ when blank) — the cover placeholder text."
  def initials(nil), do: "♪"
  def initials(""), do: "♪"

  def initials(artist) do
    artist
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  @doc "A stable two-color gradient `{a, b}` for a seed (artist) — the cover placeholder background."
  def cover_gradient(seed) do
    hash = :erlang.phash2(seed || "♪", length(@cover_palette))
    a = Enum.at(@cover_palette, hash)
    b = Enum.at(@cover_palette, rem(hash + 3, length(@cover_palette)))
    {a, b}
  end
end
