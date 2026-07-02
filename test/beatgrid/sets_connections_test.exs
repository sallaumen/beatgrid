defmodule Beatgrid.SetsConnectionsTest do
  use Beatgrid.DataCase, async: true

  import Beatgrid.Factory

  alias Beatgrid.Repo
  alias Beatgrid.Sets

  defp with_song(track), do: Repo.preload(track, :soundcharts_song)

  describe "suggest_transition/2" do
    # Every suggestion track carries out+intro markers so the choice is driven by
    # BPM/energy/key, not by the missing-marker fallback.
    defp mixable(bpm, attrs \\ []) do
      base = [
        status: :present,
        bpm_detected: bpm,
        duration_ms: 200_000,
        cue_points: [
          %{"ms" => 150_000, "type" => "outro", "source" => "auto"},
          %{"ms" => 4_000, "type" => "intro", "source" => "auto"}
        ]
      ]

      insert(:track, Keyword.merge(base, attrs)) |> with_song()
    end

    test "cut when a marker is missing" do
      a = mixable(128.0)
      c = insert(:track, status: :present, bpm_detected: 130.0, cue_points: []) |> with_song()
      assert Sets.suggest_transition(a, c)["type"] == "cut"
      assert Sets.suggest_transition(a, c)["reason"] =~ "Sem marcadores"
    end

    test "close BPM with unknown keys → crossfade, carrying its from/to markers" do
      a = mixable(128.0)
      b = mixable(130.0)
      t = Sets.suggest_transition(a, b)
      assert t["type"] == "crossfade"
      assert t["from_ms"] == 150_000
      assert t["to_ms"] == 4_000
      assert t["reason"] =~ "casado"
    end

    test "a big BPM jump UP → brake (rare, dramatic); a big drop → afunda" do
      slow = mixable(100.0)
      fast = mixable(150.0)
      assert Sets.suggest_transition(slow, fast)["type"] == "brake"
      assert Sets.suggest_transition(fast, slow)["type"] == "lowpass"
    end

    test "a moderate BPM gap → echo (the tail masks the tempo change)" do
      a = mixable(120.0)
      b = mixable(133.0)
      assert Sets.suggest_transition(a, b)["type"] == "echo"
    end

    test "close BPM but an energy jump up → filter; energy drop → fade" do
      hot = insert(:soundcharts_song, energy: 0.85)
      cool = insert(:soundcharts_song, energy: 0.35)
      a = mixable(128.0, soundcharts_song_id: cool.id) |> with_song()
      b = mixable(130.0, soundcharts_song_id: hot.id) |> with_song()
      assert Sets.suggest_transition(a, b)["type"] == "filter"
      assert Sets.suggest_transition(b, a)["type"] == "fade"
    end

    test "close BPM with clashing keys → bass swap (sidesteps the harmonic clash)" do
      clash_a = insert(:soundcharts_song, camelot: "8A", energy: 0.5)
      clash_b = insert(:soundcharts_song, camelot: "3B", energy: 0.5)
      a = mixable(128.0, soundcharts_song_id: clash_a.id) |> with_song()
      b = mixable(130.0, soundcharts_song_id: clash_b.id) |> with_song()
      assert Sets.suggest_transition(a, b)["type"] == "bass_swap"
    end

    test "the transition vocabulary includes the console classics, in UI order" do
      assert Sets.transition_types() ==
               ~w(cut fade crossfade echo filter bass_swap brake lowpass)
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

  test "an invalid transition type degrades to the safest behavior: cut" do
    {:ok, set} = Sets.create("S")
    a = insert(:track, status: :present)
    b = insert(:track, status: :present)
    {:ok, _} = Sets.append(set, a)
    {:ok, _} = Sets.append(set, b)

    {:ok, _} = Sets.connect(set, b, %{"type" => "bogus"})
    assert Enum.find(Sets.entries(set), &(&1.track.id == b.id)).transition["type"] == "cut"
  end

  describe "entry_after/2 (the console hint)" do
    test "returns the next entry with clamped transition and playback facts" do
      {:ok, set} = Sets.create("S")

      a =
        insert(:track,
          status: :present,
          bpm_detected: 100.0,
          duration_ms: 200_000,
          cue_points: [%{"ms" => 30_000, "type" => "outro", "source" => "auto"}]
        )

      b =
        insert(:track,
          status: :present,
          bpm_detected: 130.0,
          duration_ms: 180_000,
          cue_points: [%{"ms" => 4_000, "type" => "intro", "source" => "auto"}]
        )

      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect_all(set)

      hint = Sets.entry_after(set.id, a.id)

      assert hint.track.id == b.id
      assert hint.position == 2
      assert hint.bpm == 130.0
      assert hint.outgoing_bpm == 100.0
      assert hint.duration_ms == 180_000
      assert [%{"type" => "intro"}] = hint.markers

      # 100→130 BPM is a +30% jump → brake (the big-jump case); the persisted
      # outro sat mid-song (30s of 200s), so the hint clamps from_ms to the
      # outgoing track's back half, away from the "salto no meio" bug
      assert hint.transition["type"] == "brake"
      assert hint.transition["from_ms"] == 100_000
    end

    test "a missing from_ms falls back to an end window, clear of the tail" do
      {:ok, set} = Sets.create("S")
      a = insert(:track, status: :present, duration_ms: 200_000)
      b = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect(set, b, %{"type" => "crossfade", "from_ms" => nil})

      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 192_000
    end

    test "nil for the last track, an unknown track, and sequential (no transition) entries" do
      {:ok, set} = Sets.create("S")
      a = insert(:track, status: :present)
      b = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)

      assert Sets.entry_after(set.id, b.id) == nil
      assert Sets.entry_after(set.id, Ecto.UUID.generate()) == nil
      assert Sets.entry_after(set.id, a.id).transition == nil
    end
  end

  test "structural mutations broadcast {:set_changed, id} for hint revalidation" do
    {:ok, set} = Sets.create("S")
    Sets.subscribe_set(set.id)

    a = insert(:track, status: :present)
    b = insert(:track, status: :present)

    {:ok, _} = Sets.append(set, a)
    assert_receive {:set_changed, _}

    {:ok, _} = Sets.append(set, b)
    assert_receive {:set_changed, _}

    Sets.move(set, b, :top)
    assert_receive {:set_changed, _}

    {:ok, _} = Sets.connect(set, b, %{"type" => "cut"})
    assert_receive {:set_changed, _}

    {:ok, _} = Sets.disconnect(set, b)
    assert_receive {:set_changed, _}

    :ok = Sets.remove(set, b)
    assert_receive {:set_changed, _}
  end
end
