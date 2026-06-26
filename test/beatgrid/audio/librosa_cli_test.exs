defmodule Beatgrid.Audio.LibrosaCliTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.LibrosaCli

  @fixture Path.expand(Path.join([__DIR__, "..", "..", "support", "fixtures", "sample.mp3"]))

  describe "parse/1" do
    test "parses the analyzer JSON line" do
      assert {:ok, %{bpm: 128.0, key: 9, mode: 0}} =
               LibrosaCli.parse(~s({"bpm":128.0,"key":9,"mode":0}))
    end

    test "coerces an integer bpm to a float" do
      assert {:ok, %{bpm: 120.0}} = LibrosaCli.parse(~s({"bpm":120,"key":0,"mode":1}))
    end

    test "errors on non-JSON or unexpected shapes" do
      assert {:error, _} = LibrosaCli.parse("boom")
      assert {:error, _} = LibrosaCli.parse(~s({"bpm":120}))
    end
  end

  # `:librosa`-tagged: runs the real python+librosa script; excluded by default.
  @tag :librosa
  test "analyzes a real mp3 via the librosa script" do
    # the fixture is a ~1s clip — too short for a real tempo (bpm 0.0) — so this
    # asserts the real pipeline runs and returns the right shape, not exact values.
    assert {:ok, %{bpm: bpm, key: key, mode: mode}} = LibrosaCli.analyze(@fixture)
    assert is_float(bpm) and bpm >= 0
    assert key in 0..11
    assert mode in 0..1
  end
end
