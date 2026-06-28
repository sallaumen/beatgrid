defmodule Beatgrid.Audio.SetSegmenter do
  @moduledoc """
  Port for splitting a recorded mix into segments and analyzing each one's BPM/key.
  Given `boundaries_ms` (start-ms of each track), the adapter analyzes those windows;
  given an empty list, it auto-detects boundaries from the audio first.
  """

  @type seg :: %{
          start_ms: integer(),
          end_ms: integer(),
          bpm: float() | nil,
          key: integer() | nil,
          mode: integer() | nil
        }

  @type candidate :: %{start_ms: integer(), strength: float()}

  @callback analyze(audio_path :: String.t(), boundaries_ms :: [integer()], opts :: keyword()) ::
              {:ok, [seg()]} | {:error, term()}

  @callback dj_candidates(audio_path :: String.t()) ::
              {:ok, [candidate()]} | {:error, term()}
end
