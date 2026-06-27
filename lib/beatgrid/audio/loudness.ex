defmodule Beatgrid.Audio.Loudness do
  @moduledoc """
  Port for measuring a track's perceived loudness. The real adapter is
  `Beatgrid.Audio.FfmpegLoudness` (ffmpeg's `loudnorm` filter); tests use
  `Beatgrid.Audio.LoudnessMock`.
  """
  @callback measure(path :: String.t()) ::
              {:ok, %{lufs: float(), true_peak: float() | nil, lra: float() | nil}}
              | {:error, term()}
end
