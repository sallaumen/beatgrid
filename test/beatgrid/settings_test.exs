defmodule Beatgrid.SettingsTest do
  # async: false — Settings caches overrides in a global :persistent_term.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.{Gold, Loudness, Settings}
  alias Beatgrid.Organization.ClassificationAI

  setup do
    Settings.invalidate()
    on_exit(fn -> Settings.invalidate() end)
  end

  test "get/2 falls back to the default when nothing is stored" do
    assert Settings.get(:target_lufs, -14.0) == -14.0
  end

  test "put/2 overrides, survives a cache drop, and delete/1 restores the default" do
    assert {:ok, _} = Settings.put(:target_lufs, -12.0)
    assert Settings.get(:target_lufs, -14.0) == -12.0

    Settings.invalidate()
    assert Settings.get(:target_lufs, -14.0) == -12.0

    assert :ok = Settings.delete(:target_lufs)
    assert Settings.get(:target_lufs, -14.0) == -14.0
  end

  test "put/2 replaces an existing override instead of duplicating the key" do
    assert {:ok, _} = Settings.put(:gain_tolerance_db, 0.5)
    assert {:ok, _} = Settings.put(:gain_tolerance_db, 2.0)

    assert Settings.get(:gain_tolerance_db, 1.0) == 2.0
    assert [_only_row] = Repo.all(Beatgrid.Settings.Setting)
  end

  test "the tunables read through Settings at runtime" do
    assert {:ok, _} = Settings.put(:target_lufs, -12.0)
    assert {:ok, _} = Settings.put(:gain_tolerance_db, 0.2)
    assert {:ok, _} = Settings.put(:gold_view_threshold, 5)
    assert {:ok, _} = Settings.put(:auto_file_confidence, 0.95)

    assert Loudness.target_lufs() == -12.0
    assert Loudness.gain_db(-20.0, nil) == 8.0
    assert Loudness.gain_tolerance_db() == 0.2
    assert Gold.view_threshold() == 5
    assert ClassificationAI.auto_file_confidence() == 0.95
  end
end
