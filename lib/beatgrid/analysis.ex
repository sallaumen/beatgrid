defmodule Beatgrid.Analysis do
  @moduledoc """
  Local audio analysis — runs the `Audio.Analyzer` port on a track's file and
  stores the detected BPM + Camelot alongside the Soundcharts metadata, as a free,
  offline second opinion (useful to spot suspect Soundcharts values). Use
  `analyze_track/1`; `mix beatgrid.analyze` backfills the whole library.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{Track, Tracks}
  alias Beatgrid.Soundcharts.Camelot

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Audio.Analyzer, :adapter],
             Beatgrid.Audio.LibrosaCli
           )

  @spec analyze_track(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def analyze_track(%Track{} = track) do
    with {:ok, %{bpm: bpm, key: key, mode: mode}} <- @adapter.analyze(abs_path(track)) do
      Tracks.update(track, %{
        bpm_detected: bpm,
        camelot_detected: Camelot.from_key(key, mode),
        analyzed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
    end
  end

  defp abs_path(track), do: Path.join(Library.library_root(), track.rel_path)
end
