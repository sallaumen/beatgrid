defmodule Beatgrid.Audio.MarkerDetector do
  @moduledoc """
  Port for detecting cue markers of ONE track via audio analysis — the intro end,
  the outro start, structural sections, and the beat grid. The real adapter is
  `Beatgrid.Audio.MarkerDetectorCli` (librosa); tests use
  `Beatgrid.Audio.MarkerDetectorMock`. All positions are milliseconds, beat-snapped.
  """
  @type detection :: %{
          intro_ms: non_neg_integer() | nil,
          outro_ms: non_neg_integer() | nil,
          beat_ms: non_neg_integer() | nil,
          bpm: float() | nil,
          sections: [non_neg_integer()]
        }

  @callback detect(path :: String.t()) :: {:ok, detection()} | {:error, term()}
end
