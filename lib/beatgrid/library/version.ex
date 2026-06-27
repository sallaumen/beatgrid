defmodule Beatgrid.Library.Version do
  @moduledoc """
  Detects a track's *version* from its title — live, acoustic, remix, remaster… —
  and a `base_title` with the version marker stripped, so different versions of the
  same song can be linked together.

  This complements `Normalize`: normalization keeps the marker words ("song live"),
  which is what already keeps marked versions out of the same dedup group; here we
  pull the marker out so "Song" and "Song (Live)" share a `base_key` and show up as
  versions of each other.
  """
  alias Beatgrid.Library.Normalize

  # {regex over the NORMALIZED (lowercased, accent-stripped) title, canonical PT label}.
  # Order is priority — more specific first.
  @markers [
    {~r/\bao vivo\b|\blive\b/, "ao vivo"},
    {~r/\bacustico\b|\bacoustic\b|\bunplugged\b/, "acústico"},
    {~r/\bacapella\b|\ba cappella\b|\bcappella\b/, "acapella"},
    {~r/\bremaster\w*\b|\bremasteriz\w*\b/, "remaster"},
    {~r/\bradio edit\b|\bradio version\b/, "radio edit"},
    {~r/\bextended\b/, "extended"},
    {~r/\bremix\b|\brmx\b/, "remix"},
    {~r/\bvip\b/, "vip"},
    {~r/\bmashup\b|\bmash up\b/, "mashup"},
    {~r/\bbootleg\b/, "bootleg"},
    {~r/\bsped up\b|\bspeed up\b/, "sped up"},
    {~r/\bslowed\b/, "slowed"},
    {~r/\binstrumental\b/, "instrumental"},
    {~r/\bplayback\b|\bkaraoke\b/, "playback"},
    {~r/\bdemo\b/, "demo"},
    {~r/\bedit\b/, "edit"}
  ]

  # Stripped from the base title (but not labeled) only WHEN a marker is present,
  # so "Imagine (Remastered 2011)" and "Track (Extended Mix)" collapse to the same
  # base as the original — without touching a song genuinely titled e.g. "1979".
  @qualifiers ~r/\b(19|20)\d{2}\b|\bmix\b/

  @doc "Canonical version label for a title (e.g. ao vivo, remix), or nil for an original."
  @spec label(String.t() | nil) :: String.t() | nil
  def label(title) do
    norm = Normalize.normalize(title)
    Enum.find_value(@markers, fn {re, lbl} -> if Regex.match?(re, norm), do: lbl end)
  end

  @doc """
  Normalized title with every version marker stripped — the shared key across
  versions. Falls back to the full normalized title if stripping leaves it empty
  (e.g. a track literally titled \"Live\").
  """
  @spec base_title(String.t() | nil) :: String.t()
  def base_title(title) do
    norm = Normalize.normalize(title)
    marked? = Enum.any?(@markers, fn {re, _lbl} -> Regex.match?(re, norm) end)

    stripped =
      @markers
      |> Enum.reduce(norm, fn {re, _lbl}, acc -> Regex.replace(re, acc, " ") end)
      |> drop_qualifiers(marked?)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if stripped == "", do: norm, else: stripped
  end

  defp drop_qualifiers(text, true), do: Regex.replace(@qualifiers, text, " ")
  defp drop_qualifiers(text, false), do: text

  @doc "Version-group key `norm_artist|base_title` — same key = versions of the same song."
  @spec base_key(String.t() | nil, String.t() | nil) :: String.t()
  def base_key(artist, title), do: "#{Normalize.normalize(artist)}|#{base_title(title)}"
end
