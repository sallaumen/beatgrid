defmodule Beatgrid.Library.Marker do
  @moduledoc """
  Cue-point marker vocabulary. Markers are plain JSON maps stored in
  `tracks.cue_points` (`%{"ms", "label", "type", "source"}`). Legacy markers lack
  `type`/`source`, so every getter defaults safely (`cue` / `manual`). The
  `intro`/`outro` selectors pick the entry/exit points the set-transition engine
  wires (exit of A → entry of B).
  """
  @types ~w(cue intro outro)
  @colors %{"cue" => "#ffb020", "intro" => "#5ad1a0", "outro" => "#ff5d6c"}

  @doc "Marker type (`cue` | `intro` | `outro`); legacy/unknown → `cue`."
  def type(%{"type" => t}) when t in @types, do: t
  def type(_marker), do: "cue"

  @doc "Marker origin (`manual` | `auto`); anything but `auto` → `manual`."
  def source(%{"source" => "auto"}), do: "auto"
  def source(_marker), do: "manual"

  @doc "True when the marker was placed by audio analysis."
  def source_auto?(marker), do: source(marker) == "auto"
  def auto?(marker), do: source(marker) == "auto"

  @doc "Hex color for a marker, by type."
  def color(marker), do: Map.fetch!(@colors, type(marker))

  @doc "The known marker types, in display order."
  def types, do: @types

  @doc "Coerce a client-supplied type to a known one (`cue` fallback)."
  def normalize_type(t) when t in @types, do: t
  def normalize_type(_t), do: "cue"

  @doc "Coerce a client-supplied source (`manual` fallback)."
  def normalize_source("auto"), do: "auto"
  def normalize_source(_s), do: "manual"

  @doc "Earliest `intro` marker of a track (nil if none) — the entry/mix-in point."
  def intro(track), do: pick(track, "intro", :min)

  @doc "Latest `outro` marker of a track (nil if none) — the exit/mix-out point."
  def outro(track), do: pick(track, "outro", :max)

  defp pick(track, t, dir) do
    case Enum.filter(track.cue_points || [], &(type(&1) == t)) do
      [] -> nil
      cues when dir == :min -> Enum.min_by(cues, & &1["ms"])
      cues -> Enum.max_by(cues, & &1["ms"])
    end
  end
end
