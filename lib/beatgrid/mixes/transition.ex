defmodule Beatgrid.Mixes.Transition do
  @moduledoc """
  Pure analysis of the "troca" between two consecutive segments: the harmonic
  (Camelot) relationship and the BPM delta. Nothing is stored — segments already
  carry their own BPM/Camelot, so transitions are derived on the fly.
  """

  alias Beatgrid.Soundcharts.Camelot

  @type relation :: :perfect | :compatible | :clash | :unknown
  @type t :: %{camelot: relation(), bpm_delta: float() | nil}

  @spec between(map(), map()) :: t()
  def between(from, to) do
    %{
      camelot: camelot_relation(from.camelot_detected, to.camelot_detected),
      bpm_delta: bpm_delta(from.bpm_detected, to.bpm_detected)
    }
  end

  defp camelot_relation(a, b) when is_nil(a) or is_nil(b), do: :unknown
  defp camelot_relation(a, a), do: :perfect
  defp camelot_relation(a, b), do: if(Camelot.compatible?(a, b), do: :compatible, else: :clash)

  defp bpm_delta(a, b) when is_number(a) and is_number(b), do: Float.round(b - a, 1)
  defp bpm_delta(_a, _b), do: nil
end
