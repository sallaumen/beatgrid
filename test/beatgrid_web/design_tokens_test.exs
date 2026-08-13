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
