defmodule Beatgrid.Settings.RegistryTest do
  # async: false — reads the owners' effective values through the global
  # Settings cache; every test starts (and leaves) it cold, no override set.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Settings
  alias Beatgrid.Settings.Registry

  setup do
    Settings.invalidate()
    on_exit(fn -> Settings.invalidate() end)
  end

  test "every entry's default matches the owner's real fallback (no override set)" do
    for entry <- Registry.all() do
      assert entry.effective.() == entry.default,
             "#{entry.key}: registry default #{entry.default} " <>
               "!= owner fallback #{entry.effective.()}"
    end
  end

  test "the catalog covers exactly the runtime tunables" do
    assert Enum.map(Registry.all(), & &1.key) == [
             :target_lufs,
             :gain_tolerance_db,
             :gold_view_threshold,
             :instrumental_min,
             :auto_file_confidence
           ]
  end

  describe "parse/2" do
    test "accepts in-range values of the right type" do
      assert {:ok, -12.5} = Registry.parse(:target_lufs, "-12.5")
      assert {:ok, +0.0} = Registry.parse(:target_lufs, "0")
      assert {:ok, 2_000_000} = Registry.parse(:gold_view_threshold, "2000000")
      assert {:ok, 0.35} = Registry.parse(:instrumental_min, "0.35")
    end

    test "rejects out-of-range, wrong-type and garbage" do
      assert :error = Registry.parse(:target_lufs, "5")
      assert :error = Registry.parse(:instrumental_min, "1.5")
      assert :error = Registry.parse(:gold_view_threshold, "1.5")
      assert :error = Registry.parse(:gold_view_threshold, "-1")
      assert :error = Registry.parse(:target_lufs, "abc")
      assert :error = Registry.parse(:unknown_key, "1")
    end
  end

  test "override?/1 reflects a stored override, by_param/1 finds entries safely" do
    refute Registry.override?(:target_lufs)

    {:ok, _} = Settings.put(:target_lufs, -12.0)
    assert Registry.override?(:target_lufs)

    assert %{key: :target_lufs} = Registry.by_param("target_lufs")
    assert Registry.by_param("os:cmd") == nil
  end
end
