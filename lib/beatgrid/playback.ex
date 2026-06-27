defmodule Beatgrid.Playback do
  @moduledoc """
  Backend-owned playback parameters (single source of truth), consumed by the
  global player hook via data attributes. Kept here — not hardcoded in JS — so the
  rule can be changed/consulted from the backend.
  """

  alias Beatgrid.Playback.NowPlaying

  @preview_offset_ms 20_000
  @preview_min_duration_ms 25_000

  # ── Now-playing pointer (app-wide) ──────────────────────────────────────────

  @doc "Current now-playing pointer `%{track_id, set_id}` — read on mount."
  defdelegate now_playing(), to: NowPlaying, as: :get

  @doc "Set the now-playing pointer and broadcast the change."
  defdelegate set_now_playing(state), to: NowPlaying, as: :put

  @doc "Clear the now-playing pointer (nothing playing) and broadcast."
  defdelegate clear_now_playing(), to: NowPlaying, as: :clear

  @doc "Subscribe the caller to now-playing updates (`{:now_playing, %{track_id, set_id}}`)."
  defdelegate subscribe(), to: NowPlaying

  @doc "Where a preview play starts (ms) for tracks at least `preview_min_duration_ms/0` long."
  @spec preview_offset_ms() :: pos_integer()
  def preview_offset_ms, do: @preview_offset_ms

  @doc "Minimum track length (ms) for a preview play to jump to `preview_offset_ms/0`; shorter tracks start at 0."
  @spec preview_min_duration_ms() :: pos_integer()
  def preview_min_duration_ms, do: @preview_min_duration_ms
end
