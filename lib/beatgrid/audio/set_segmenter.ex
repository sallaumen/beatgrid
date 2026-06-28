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

  @callback analyze(audio_path :: String.t(), boundaries_ms :: [integer()]) ::
              {:ok, [seg()]} | {:error, term()}
end
