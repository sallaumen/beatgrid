defmodule Beatgrid.Audio.Analyzer do
  @moduledoc """
  Port for local audio analysis (BPM + musical key) of a file on disk — a free,
  offline second opinion alongside the Soundcharts metadata. The real adapter is
  `Beatgrid.Audio.LibrosaCli`; tests use `Beatgrid.Audio.AnalyzerMock`.

  Returns the detected tempo and a pitch-class `key` (0=C … 11=B) + `mode`
  (1=major, 0=minor), which the domain turns into a Camelot code.
  """

  @callback analyze(path :: String.t()) ::
              {:ok, %{bpm: float(), key: integer(), mode: integer()}} | {:error, term()}
end
