defmodule Beatgrid.Sets.PresetsTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Sets.Presets

  test "all/0 exposes custom plus the named presets" do
    keys = Presets.all() |> Enum.map(& &1.key)
    assert "custom" in keys
    assert "roots_to_forro_mpb" in keys
    assert length(keys) == length(Enum.uniq(keys))
  end

  test "get/1 falls back to custom for unknown keys" do
    assert Presets.get("nope").key == "custom"
    assert Presets.get("roots_to_forro_mpb").key == "roots_to_forro_mpb"
  end

  describe "to_config_fields/1 — a preset pre-fills the studio controls" do
    test "named preset whitelists the styles its journey visits" do
      fields = Presets.to_config_fields("roots_to_forro_mpb")
      assert "forro_roots" in fields.allow_styles
      assert "forro_mpb" in fields.allow_styles
      assert fields.exclude_styles == ["mpb"]
      assert fields.arc_shape == :wave
    end

    test "custom leaves the pool wide open" do
      fields = Presets.to_config_fields("custom")
      assert fields.allow_styles == []
      assert fields.exclude_styles == []
    end
  end

  describe "phase_target_style/4 — the style journey across the set" do
    test "walks from the opening style to the closing style" do
      p = Presets.get("roots_to_forro_mpb")
      assert Presets.phase_target_style(p, 0, 10, nil) == "forro_roots"
      assert Presets.phase_target_style(p, 9, 10, nil) == "forro_mpb"
    end

    test "custom inherits the set's target style for every slot" do
      p = Presets.get("custom")
      assert Presets.phase_target_style(p, 0, 10, "mpb") == "mpb"
      assert Presets.phase_target_style(p, 9, 10, "mpb") == "mpb"
    end
  end
end
