defmodule Beatgrid.SetsConnectionsTest do
  use Beatgrid.DataCase, async: true

  import Beatgrid.Factory

  alias Beatgrid.Repo
  alias Beatgrid.Sets

  defp with_song(track), do: Repo.preload(track, :soundcharts_song)

  describe "suggest_transition/2" do
    test "crossfade with intro+outro markers and close BPM; cut when a marker is missing" do
      a =
        insert(:track,
          status: :present,
          bpm_detected: 128.0,
          cue_points: [%{"ms" => 100_000, "type" => "outro", "source" => "auto"}]
        )
        |> with_song()

      b =
        insert(:track,
          status: :present,
          bpm_detected: 130.0,
          cue_points: [%{"ms" => 4_000, "type" => "intro", "source" => "auto"}]
        )
        |> with_song()

      c = insert(:track, status: :present, bpm_detected: 130.0, cue_points: []) |> with_song()

      t = Sets.suggest_transition(a, b)
      assert t["type"] == "crossfade"
      assert t["from_ms"] == 100_000
      assert t["to_ms"] == 4_000

      # No intro marker on c → cut.
      assert Sets.suggest_transition(b, c)["type"] == "cut"
    end

    test "fade when markers exist but BPMs diverge" do
      a =
        insert(:track,
          status: :present,
          bpm_detected: 100.0,
          cue_points: [%{"ms" => 90_000, "type" => "outro", "source" => "auto"}]
        )
        |> with_song()

      b =
        insert(:track,
          status: :present,
          bpm_detected: 145.0,
          cue_points: [%{"ms" => 3_000, "type" => "intro", "source" => "auto"}]
        )
        |> with_song()

      assert Sets.suggest_transition(a, b)["type"] == "fade"
    end
  end

  test "connect/disconnect set and clear an entry's transition; entries expose it" do
    {:ok, set} = Sets.create("S")
    a = insert(:track, status: :present)
    b = insert(:track, status: :present)
    {:ok, _} = Sets.append(set, a)
    {:ok, _} = Sets.append(set, b)

    {:ok, _} = Sets.connect(set, b, %{"type" => "fade", "from_ms" => 90_000, "to_ms" => 3_000})
    entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
    assert entry_b.transition["type"] == "fade"
    assert entry_b.transition["from_ms"] == 90_000
    assert entry_b.transition["enabled"] == true

    {:ok, _} = Sets.disconnect(set, b)
    assert Enum.find(Sets.entries(set), &(&1.track.id == b.id)).transition == nil
  end

  test "connect_all connects every consecutive pair (not the first entry)" do
    {:ok, set} = Sets.create("S")
    tracks = for _ <- 1..3, do: insert(:track, status: :present, bpm_detected: 128.0)
    for t <- tracks, do: Sets.append(set, t)

    assert {:ok, 2} = Sets.connect_all(set)

    [first, second, third] = Sets.entries(set)
    assert first.transition == nil
    assert second.transition["enabled"] == true
    assert third.transition["enabled"] == true
  end

  test "an invalid transition type is coerced to crossfade" do
    {:ok, set} = Sets.create("S")
    a = insert(:track, status: :present)
    b = insert(:track, status: :present)
    {:ok, _} = Sets.append(set, a)
    {:ok, _} = Sets.append(set, b)

    {:ok, _} = Sets.connect(set, b, %{"type" => "bogus"})
    assert Enum.find(Sets.entries(set), &(&1.track.id == b.id)).transition["type"] == "crossfade"
  end
end
