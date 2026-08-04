defmodule Beatgrid.SetsBreatherSettingsTest do
  # async: false — Settings overrides live in a global :persistent_term cache.
  use Beatgrid.DataCase, async: false

  import Beatgrid.Factory

  alias Beatgrid.Sets
  alias Beatgrid.Settings

  setup do
    Settings.invalidate()
    on_exit(fn -> Settings.invalidate() end)
  end

  defp breather_set(track_count) do
    tracks =
      for i <- 1..track_count do
        insert(:track,
          status: :present,
          tag_title: "T#{i}",
          duration_ms: 200_000,
          cue_points: [%{"ms" => 180_000, "type" => "outro", "source" => "auto"}]
        )
      end

    {:ok, set} = Sets.create_filled("Ajustável", tracks)
    {set, tracks}
  end

  test "the /ajustes gap flows into the hint the console fires with" do
    {set, [a | _rest]} = breather_set(5)
    {:ok, _} = Settings.put(:breather_every, 1)
    {:ok, _} = Sets.connect_all(set)

    {:ok, _} = Settings.put(:breather_gap_s, 7.5)

    assert Sets.entry_after(set.id, a.id).transition["gap_ms"] == 7_500
  end

  test "the /ajustes cadence decides the breathers BY POSITION at read time" do
    {set, _tracks} = breather_set(5)
    {:ok, _} = Sets.connect_all(set)

    {:ok, _} = Settings.put(:breather_every, 2)
    flags = set |> Sets.entries() |> Enum.drop(1) |> Enum.map(&Sets.breather?/1)
    assert flags == [false, true, false, true]

    # tightening the cadence in /ajustes re-decides EXISTING sets instantly
    {:ok, _} = Settings.put(:breather_every, 1)
    flags = set |> Sets.entries() |> Enum.drop(1) |> Enum.map(&Sets.breather?/1)
    assert flags == [true, true, true, true]
  end
end
