defmodule BeatgridWeb.DesignTokensTest do
  @moduledoc """
  Guards the `@theme` block against silently dead utility classes.

  A Tailwind class whose token is missing from `@theme` compiles to *nothing* —
  no error, no warning, the element just inherits. That is how `text-body`,
  `text-body-sm`, `text-body-lg` and `text-caption` shipped from the first UI
  commit with ~313 uses and no definition, every one of them rendering at the
  browser's 16px default.
  """
  use ExUnit.Case, async: true

  @app_css "assets/css/app.css"
  @ui_root "lib/beatgrid_web"

  # Utilities Tailwind ships itself, so a bare `text-<name>` may legitimately
  # resolve without an @theme entry of ours.
  @builtin_sizes ~w(xs sm base lg xl 2xl 3xl 4xl 5xl 6xl 7xl 8xl 9xl)
  @builtin_keywords ~w(left right center justify start end
                       wrap nowrap balance pretty ellipsis clip)
  @builtin_colors ~w(white black transparent current inherit)
  # Roles the daisyUI plugin defines (core_components still uses a few).
  @daisy_roles ~w(base-100 base-200 base-300 base-content
                  primary-content secondary-content accent-content
                  neutral-content info-content success-content
                  warning-content error-content
                  info success warning error)
  # Stock palette families still used in a few spots (text-amber-300 …).
  @builtin_palette ~w(slate gray zinc neutral stone red orange amber yellow lime
                      green emerald teal cyan sky blue indigo violet purple
                      fuchsia pink rose)

  describe "@theme" do
    test "defines every semantic type step the UI writes" do
      theme = theme_keys()

      for step <- ~w(caption body-sm body body-lg) do
        assert "text-#{step}" in theme,
               "--text-#{step} is missing from #{@app_css} @theme, so the " <>
                 "text-#{step} class compiles to nothing and its elements inherit 16px"
      end
    end
  end

  describe "UI source" do
    test "writes no text-* class that resolves to nothing" do
      theme = theme_keys()

      dead =
        ui_files()
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> text_classes()
          |> Enum.reject(&resolvable?(&1, theme))
          |> Enum.map(&{Path.relative_to_cwd(file), &1})
        end)
        |> Enum.uniq()

      assert dead == [],
             "these text-* classes are used but defined nowhere — they compile to " <>
               "nothing and the element inherits its parent size:\n" <>
               Enum.map_join(dead, "\n", fn {file, class} -> "  #{class}  (#{file})" end)
    end
  end

  describe "colour contrast" do
    # The surfaces text and focus rings are actually drawn over, darkest first.
    @surfaces %{"base" => "#0b0c10", "rail" => "#0e0f15", "surface" => "#11131a"}

    test "every ink tone clears WCAG AA on the surfaces it lands on" do
      # ink-disabled is exempt: WCAG excludes inactive controls, and it marks
      # exactly that. Never use it for text a working DJ has to read.
      for name <- ~w(ink ink-secondary ink-muted ink-faint),
          {surface_name, surface} <- @surfaces do
        colour = theme_colour(name)
        ratio = contrast(colour, surface)

        assert ratio >= 4.5,
               "#{name} (#{colour}) over #{surface_name} is #{ratio}:1, below the 4.5:1 " <>
                 "that WCAG 1.4.3 asks of body text"
      end
    end

    test "the focus ring clears 3:1 against every surface it is drawn over" do
      ring = css_var("assets/css/tokens.css", "focus-ring")

      for {surface_name, surface} <- @surfaces do
        ratio = contrast(ring, surface)

        assert ratio >= 3.0,
               "the focus ring (#{ring}) over #{surface_name} is #{ratio}:1, below the 3:1 " <>
                 "that WCAG 1.4.11 asks of a non-text indicator. An alpha below ~0.8 composites " <>
                 "toward the dark surface and fails here even when the hue itself is bright."
      end
    end
  end

  defp theme_colour(name), do: css_var(@app_css, "color-#{name}")

  defp css_var(file, name) do
    case Regex.run(~r/--#{Regex.escape(name)}:\s*([^;]+);/, File.read!(file)) do
      [_, value] -> String.trim(value)
      _ -> flunk("no --#{name} declared in #{file}")
    end
  end

  # Composites `colour` over `background` when it carries alpha — which is what
  # the browser does, and what makes a translucent ring fail against near-black.
  defp contrast(colour, background) do
    l1 = luminance(flatten(colour, background))
    l2 = luminance(flatten(background, background))
    Float.round((max(l1, l2) + 0.05) / (min(l1, l2) + 0.05), 2)
  end

  defp flatten("#" <> _ = hex, _background), do: rgb(hex)

  defp flatten(rgba, background) do
    [r, g, b, a] =
      ~r/[\d.]+/
      |> Regex.scan(rgba)
      |> Enum.map(fn [n] ->
        String.to_float(if String.contains?(n, "."), do: n, else: n <> ".0")
      end)

    bg = rgb(background)
    Enum.zip_with([[r, g, b], bg], fn [fg, back] -> fg * a + back * (1 - a) end)
  end

  defp rgb("#" <> hex) do
    hex |> String.to_charlist() |> Enum.chunk_every(2) |> Enum.map(&List.to_integer(&1, 16))
  end

  defp luminance(channels) do
    [r, g, b] =
      Enum.map(channels, fn c ->
        c = c / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end)

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  # `--color-ink-muted: …` / `--text-body: …` → "text-ink-muted" / "text-body":
  # the class name each @theme entry makes available to a `text-*` utility.
  defp theme_keys do
    css = File.read!(@app_css)

    case Regex.run(~r/@theme \{(.*?)\n\}/s, css) do
      [_, block] ->
        ~r/--(color|text)-([a-z0-9-]+)\s*:/
        |> Regex.scan(block)
        |> Enum.map(fn [_, _kind, name] -> "text-#{name}" end)

      _ ->
        flunk("no @theme block found in #{@app_css}")
    end
  end

  defp ui_files do
    Path.wildcard("#{@ui_root}/**/*.{ex,heex}")
  end

  # Bare `text-<word>` classes only. Arbitrary values (`text-[11px]`) are
  # Tailwind's business, and a trailing `=` means it is the SVG presentation
  # attribute `text-anchor="middle"`, not a class at all.
  defp text_classes(source) do
    ~r/\btext-([a-z][a-z0-9-]*)\b(?![\[=])/
    |> Regex.scan(source)
    |> Enum.map(fn [match, _name] -> match end)
    |> Enum.uniq()
  end

  defp resolvable?(class, theme) do
    "text-" <> name = class

    class in theme or
      name in @builtin_sizes or
      name in @builtin_keywords or
      name in @builtin_colors or
      name in @daisy_roles or
      palette_shade?(name)
  end

  # "amber-300" → stock palette; "amber" alone would be ours (--color-amber).
  defp palette_shade?(name) do
    case String.split(name, "-") do
      [family, shade] -> family in @builtin_palette and match?({_, ""}, Integer.parse(shade))
      _ -> false
    end
  end
end
