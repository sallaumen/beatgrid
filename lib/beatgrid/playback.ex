defmodule Beatgrid.Playback do
  @moduledoc """
  Backend-owned playback parameters (single source of truth), consumed by the
  global player hook via data attributes. Kept here — not hardcoded in JS — so the
  rule can be changed/consulted from the backend.
  """

  @preview_offset_ms 20_000
  @preview_min_duration_ms 25_000

  @doc "Where a preview play starts (ms) for tracks at least `preview_min_duration_ms/0` long."
  @spec preview_offset_ms() :: pos_integer()
  def preview_offset_ms, do: @preview_offset_ms

  @doc "Minimum track length (ms) for a preview play to jump to `preview_offset_ms/0`; shorter tracks start at 0."
  @spec preview_min_duration_ms() :: pos_integer()
  def preview_min_duration_ms, do: @preview_min_duration_ms
end
