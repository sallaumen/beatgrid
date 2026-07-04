defmodule Beatgrid.Sets.TransitionChooserTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Sets.TransitionChooser

  defp eff(bpm, camelot, energy \\ nil), do: %{bpm: bpm, camelot: camelot, energy: energy}

  defp type(a, b, opts \\ []) do
    out = Keyword.get(opts, :out, %{"ms" => 100})
    intro = Keyword.get(opts, :intro, %{"ms" => 0})
    TransitionChooser.choose(a, b, out, intro) |> elem(0)
  end

  describe "choose/4 — marker gate" do
    test "cut when either marker is missing (nothing to beat-match on)" do
      assert type(eff(120, "8A"), eff(122, "8A"), out: nil) == "cut"
      assert type(eff(120, "8A"), eff(122, "8A"), intro: nil) == "cut"
    end
  end

  describe "choose/4 — tempo-dramatic cases lead" do
    test "a big BPM jump up → brake (rare, only big jumps)" do
      assert type(eff(100, "8A"), eff(120, "8A")) == "brake"
    end

    test "a big BPM drop → lowpass (afunda)" do
      assert type(eff(120, "8A"), eff(100, "8A")) == "lowpass"
    end

    test "a moderate BPM gap → echo (the tail masks the jump)" do
      assert type(eff(120, "8A"), eff(132, "8A")) == "echo"
    end
  end

  describe "choose/4 — close BPM (≤8%): energy then harmony" do
    test "energy rising → filter" do
      assert type(eff(120, "8A", 0.40), eff(122, "8A", 0.70)) == "filter"
    end

    test "energy falling → fade" do
      assert type(eff(120, "8A", 0.70), eff(122, "8A", 0.40)) == "fade"
    end

    test "compatible key, energy unknown → crossfade (matched mix)" do
      assert type(eff(120, "8A"), eff(122, "8A")) == "crossfade"
    end

    test "clashing key, energy unknown → bass_swap (avoids the clash)" do
      assert type(eff(120, "8A"), eff(122, "3B")) == "bass_swap"
    end
  end

  describe "choose/4 — reason" do
    test "returns a human-readable reason with the tempo delta" do
      assert {"brake", reason} =
               TransitionChooser.choose(eff(100, "8A"), eff(120, "8A"), %{"ms" => 1}, %{"ms" => 0})

      assert is_binary(reason) and reason =~ "%"
    end
  end
end
