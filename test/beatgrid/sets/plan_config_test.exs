defmodule Beatgrid.Sets.PlanConfigTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Sets.PlanConfig

  test "an empty form yields safe defaults" do
    c = PlanConfig.from_params(%{})
    assert c.preset == "custom"
    assert c.mode == :duration
    assert c.arc_shape == :wave
    assert c.fill_mode == :replace
    assert c.avoid_artist_repeat == false
    assert c.allow_styles == []
    assert c.exclude_styles == []
    assert c.exclude_set_ids == []
    assert c.bpm_min == nil and c.bpm_max == nil and c.min_rating == nil
  end

  test "parses numeric fields and clamps them to safe ranges" do
    c =
      PlanConfig.from_params(%{
        "mode" => "tracks",
        "track_count" => "500",
        "duration_minutes" => "300",
        "bpm_min" => "110",
        "bpm_max" => "130",
        "min_rating" => "20"
      })

    assert c.mode == :tracks
    assert c.track_count == 240
    assert c.duration_minutes == 300
    assert c.bpm_min == 110.0
    assert c.bpm_max == 130.0
    assert c.min_rating == 10
  end

  test "track_count floors at 2 and duration_minutes at 15" do
    assert PlanConfig.from_params(%{"track_count" => "1"}).track_count == 2
    assert PlanConfig.from_params(%{"duration_minutes" => "1"}).duration_minutes == 15
  end

  test "reads the style/set-id arrays and the boolean" do
    c =
      PlanConfig.from_params(%{
        "allow_styles" => ["forro_roots", "mpb"],
        "exclude_styles" => ["forro_psicodelico"],
        "exclude_set_ids" => ["id-1", "id-2"],
        "avoid_artist_repeat" => "true"
      })

    assert c.allow_styles == ["forro_roots", "mpb"]
    assert c.exclude_styles == ["forro_psicodelico"]
    assert c.exclude_set_ids == ["id-1", "id-2"]
    assert c.avoid_artist_repeat == true
  end

  test "invalid enum values fall back to the defaults instead of crashing" do
    c = PlanConfig.from_params(%{"mode" => "bogus", "arc_shape" => "nope", "fill_mode" => "x"})
    assert c.mode == :duration
    assert c.arc_shape == :wave
    assert c.fill_mode == :replace
  end

  describe "count/2 — resolves how many tracks to plan" do
    test "tracks mode uses the count directly" do
      c = PlanConfig.from_params(%{"mode" => "tracks", "track_count" => "40"})
      assert PlanConfig.count(c, fn _ -> 999 end) == 40
    end

    test "duration mode defers to the estimator with the minutes" do
      c = PlanConfig.from_params(%{"mode" => "duration", "duration_minutes" => "60"})
      assert PlanConfig.count(c, fn 60 -> 18 end) == 18
    end
  end
end
