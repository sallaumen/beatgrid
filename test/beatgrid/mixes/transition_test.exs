defmodule Beatgrid.Mixes.TransitionTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Mixes.Segment
  alias Beatgrid.Mixes.Transition

  defp seg(camelot, bpm), do: %Segment{camelot_detected: camelot, bpm_detected: bpm}

  test "same key is :perfect, neighbor is :compatible, distant is :clash" do
    assert Transition.between(seg("8A", 120.0), seg("8A", 124.0)).camelot == :perfect
    assert Transition.between(seg("8A", 120.0), seg("9A", 120.0)).camelot == :compatible
    assert Transition.between(seg("8A", 120.0), seg("2B", 120.0)).camelot == :clash
  end

  test ":unknown when either Camelot is missing" do
    assert Transition.between(seg(nil, 120.0), seg("8A", 120.0)).camelot == :unknown
    assert Transition.between(seg("8A", 120.0), seg(nil, 120.0)).camelot == :unknown
  end

  test "bpm_delta is b - a rounded, or nil when a bpm is missing" do
    assert Transition.between(seg("8A", 120.0), seg("8A", 124.5)).bpm_delta == 4.5
    assert Transition.between(seg("8A", nil), seg("8A", 124.0)).bpm_delta == nil
  end
end
