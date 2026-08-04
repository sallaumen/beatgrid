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

    test "close BPM with unknown keys → crossfade; a suggestion is a decision, not a timing" do
      a = mixable(128.0)
      b = mixable(130.0)
      t = Sets.suggest_transition(a, b)
      assert t["type"] == "crossfade"
      assert t["reason"] =~ "casado"
      refute Map.has_key?(t, "from_ms")
      refute Map.has_key?(t, "to_ms")
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

    test "the transition vocabulary includes the console classics + scratch drops, in UI order" do
      assert Sets.transition_types() ==
               ~w(cut fade crossfade echo filter bass_swap brake lowpass scratch_cut spinback chirp transform scribble)
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
    assert entry_b.transition["enabled"] == true
    # Timing never persists — the console derives it from the CURRENT markers.
    refute Map.has_key?(entry_b.transition, "from_ms")
    refute Map.has_key?(entry_b.transition, "to_ms")

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

      # 100→130 BPM is a +30% jump → brake (the big-jump case); a mid-song outro
      # (30s of 200s — the old "salto no meio") is noise, not a mix-out point, so
      # the hint falls back to the end window instead of firing mid-music
      assert hint.transition["type"] == "brake"
      assert hint.transition["from_ms"] == 192_000
    end

    test "no outro marker on the outgoing track → end window, clear of the tail" do
      {:ok, set} = Sets.create("S")
      a = insert(:track, status: :present, duration_ms: 200_000)
      b = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect(set, b, %{"type" => "crossfade"})

      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 192_000
    end

    test "timing is derived from CURRENT markers, never from the persisted row" do
      {:ok, set} = Sets.create("S")

      a =
        insert(:track,
          status: :present,
          duration_ms: 200_000,
          cue_points: [%{"ms" => 180_000, "type" => "outro", "source" => "auto"}]
        )

      b =
        insert(:track,
          status: :present,
          cue_points: [%{"ms" => 4_000, "type" => "intro", "source" => "auto"}]
        )

      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect(set, b, %{"type" => "crossfade"})
      legacy_row_with_stale_timing(set, b, 60_000, 52_000)

      hint = Sets.entry_after(set.id, a.id)

      assert hint.transition["from_ms"] == 180_000
      assert hint.transition["to_ms"] == 4_000
    end

    test "an outro hugging the tail keeps a minimum runway before the end" do
      {:ok, set} = Sets.create("S")

      a =
        insert(:track,
          status: :present,
          duration_ms: 200_000,
          cue_points: [%{"ms" => 199_000, "type" => "outro", "source" => "auto"}]
        )

      b = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect(set, b, %{"type" => "cut"})

      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 197_000
    end

    test "a short intro is skipped; a LONG quiet head is real music and plays from the top" do
      {:ok, set} = Sets.create("S")
      a = insert(:track, status: :present, duration_ms: 200_000)

      slow_opening =
        insert(:track,
          status: :present,
          cue_points: [%{"ms" => 52_000, "type" => "intro", "source" => "auto"}]
        )

      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, slow_opening)
      {:ok, _} = Sets.connect(set, slow_opening, %{"type" => "echo"})

      assert Sets.entry_after(set.id, a.id).transition["to_ms"] == 0
    end

    test "a disabled transition hints as plain sequential play" do
      {:ok, set} = Sets.create("S")
      a = insert(:track, status: :present, duration_ms: 200_000)
      b = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect(set, b, %{"type" => "fade", "enabled" => false})

      entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
      assert entry_b.transition["enabled"] == false
      assert Sets.entry_after(set.id, a.id).transition == nil
    end

    test "derived_timing exposes the exact points a hint would fire and enter at" do
      outgoing =
        insert(:track,
          status: :present,
          duration_ms: 200_000,
          cue_points: [%{"ms" => 180_000, "type" => "outro", "source" => "auto"}]
        )

      incoming =
        insert(:track,
          status: :present,
          cue_points: [%{"ms" => 4_000, "type" => "intro", "source" => "auto"}]
        )

      assert Sets.derived_timing(outgoing, incoming) == %{from_ms: 180_000, to_ms: 4_000}

      bare = insert(:track, status: :present, duration_ms: 200_000)
      assert Sets.derived_timing(bare, incoming) == %{from_ms: 192_000, to_ms: 4_000}
    end

    # Simulates a pre-derivation row: timing frozen into the JSON at plan time.
    defp legacy_row_with_stale_timing(set, track, from_ms, to_ms) do
      row = Repo.get_by!(Beatgrid.Sets.SetTrack, rec_set_id: set.id, track_id: track.id)
      stale = Map.merge(row.transition, %{"from_ms" => from_ms, "to_ms" => to_ms})
      {:ok, _} = row |> Ecto.Changeset.change(transition: stale) |> Repo.update()
    end
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

  describe "respiro (the salão breathes every N songs)" do
    defp eight_track_set do
      {:ok, set} = Sets.create("Baile")

      tracks =
        for i <- 1..8 do
          track =
            insert(:track,
              status: :present,
              bpm_detected: 100.0,
              duration_ms: 200_000,
              cue_points: [%{"ms" => 180_000, "type" => "outro", "source" => "auto"}]
            )

          {:ok, _} = Sets.append(set, track)
          {i, track}
        end

      {set, Map.new(tracks)}
    end

    test "connect_all marks every 4th boundary as a breather (echo treatment, cultural reason)" do
      {set, _tracks} = eight_track_set()

      {:ok, 7} = Sets.connect_all(set)

      breathers =
        for {e, idx} <- Enum.with_index(Sets.entries(set)),
            idx > 0,
            e.transition["breather"] == true,
            do: idx

      # boundaries are 1-based between positions: 4th boundary = entry index 4
      assert breathers == [4]
      breather = Enum.at(Sets.entries(set), 4).transition
      assert breather["type"] == "echo"
      assert breather["reason"] =~ "Respiro"
    end

    test "breather_every option changes the cadence; nil disables it" do
      {set, _tracks} = eight_track_set()

      {:ok, 7} = Sets.connect_all(set, breather_every: 3)
      idxs = for {e, i} <- Enum.with_index(Sets.entries(set)), e.transition["breather"], do: i
      assert idxs == [3, 6]

      {:ok, 7} = Sets.connect_all(set, breather_every: nil)
      assert Enum.all?(Sets.entries(set), &(&1.transition["breather"] != true))
    end

    test "a breather hint plays to the REAL end (outro marker ignored) and carries the gap" do
      {set, tracks} = eight_track_set()
      {:ok, 7} = Sets.connect_all(set)

      # boundary 4 = from track 4 into track 5; outro at 180s would normally win
      hint = Sets.entry_after(set.id, tracks[4].id)

      assert hint.transition["breather"] == true
      assert hint.transition["from_ms"] == 196_000
      assert hint.transition["gap_ms"] == 5_000
    end

    test "set_breather toggles the flag on one boundary, surviving normalize" do
      {set, tracks} = eight_track_set()
      {:ok, 7} = Sets.connect_all(set)

      {:ok, _} = Sets.set_breather(set, tracks[2], true)
      assert Enum.at(Sets.entries(set), 1).transition["breather"] == true

      {:ok, _} = Sets.set_breather(set, tracks[2], false)
      refute Map.has_key?(Enum.at(Sets.entries(set), 1).transition, "breather")
    end

    test "a breather boundary never learns a fire point" do
      {set, tracks} = eight_track_set()
      {:ok, 7} = Sets.connect_all(set)

      assert :ignored = Sets.learn_fire_point(set.id, tracks[5].id, tracks[4].id, 120_000)
    end

    test "a sacred ending fires only at the very end, beating markers (human hand still wins)" do
      {:ok, set} = Sets.create("S")

      a =
        insert(:track,
          status: :present,
          sacred_ending: true,
          duration_ms: 200_000,
          cue_points: [%{"ms" => 180_000, "type" => "outro", "source" => "auto"}]
        )

      b = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect(set, b, %{"type" => "cut"})

      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 198_500

      # a REAL fire the DJ performed still beats the sacred flag
      {:ok, _} = Sets.learn_fire_point(set.id, b.id, a.id, 120_000)
      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 120_000
    end
  end

  describe "adopt_memberships/2 (dedup hands set seats to the keeper)" do
    test "a duplicate's seat moves to the keeper, keeping order and transition" do
      {:ok, set} = Sets.create("S")
      loser = insert(:track, status: :present)
      keeper = insert(:track, status: :present)
      other = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, loser)
      {:ok, _} = Sets.append(set, other)
      {:ok, _} = Sets.connect(set, other, %{"type" => "echo"})
      Sets.subscribe_set(set.id)

      assert {:ok, 1} = Sets.adopt_memberships(loser.id, keeper.id)
      assert_receive {:set_changed, _}

      entries = Sets.entries(set)
      assert Enum.map(entries, & &1.track.id) == [keeper.id, other.id]
      assert Enum.at(entries, 1).transition["type"] == "echo"
    end

    test "keeper already in the set → the duplicate's row is dropped and the order closes" do
      {:ok, set} = Sets.create("S")
      keeper = insert(:track, status: :present)
      loser = insert(:track, status: :present)
      last = insert(:track, status: :present)
      {:ok, _} = Sets.append(set, keeper)
      {:ok, _} = Sets.append(set, loser)
      {:ok, _} = Sets.append(set, last)

      assert {:ok, 1} = Sets.adopt_memberships(loser.id, keeper.id)

      entries = Sets.entries(set)
      assert Enum.map(entries, & &1.track.id) == [keeper.id, last.id]
      assert Enum.map(entries, & &1.position) == [1, 2]
    end

    test "a track in no set is a quiet no-op" do
      loose = insert(:track, status: :present)
      keeper = insert(:track, status: :present)
      assert {:ok, 0} = Sets.adopt_memberships(loose.id, keeper.id)
    end

    test "set_health/0 counts seats pointing at tracks that left the library" do
      {:ok, healthy} = Sets.create("Sã")
      {:ok, sick} = Sets.create("Doente")
      ok_track = insert(:track, status: :present)
      gone = insert(:track, status: :quarantined)
      {:ok, _} = Sets.append(healthy, ok_track)
      {:ok, _} = Sets.append(sick, ok_track)
      {:ok, _} = Sets.append(sick, gone)

      health = Sets.set_health()
      assert health[sick.id] == 1
      refute Map.has_key?(health, healthy.id)
    end
  end

  describe "learn_fire_point/4 (the console learns real fires)" do
    # 200s outgoing with a trusted outro at 180s (90%) → derived from = 180_000.
    defp connected_pair do
      {:ok, set} = Sets.create("S")

      a =
        insert(:track,
          status: :present,
          duration_ms: 200_000,
          cue_points: [%{"ms" => 180_000, "type" => "outro", "source" => "auto"}]
        )

      b =
        insert(:track,
          status: :present,
          cue_points: [%{"ms" => 4_000, "type" => "intro", "source" => "auto"}]
        )

      {:ok, _} = Sets.append(set, a)
      {:ok, _} = Sets.append(set, b)
      {:ok, _} = Sets.connect(set, b, %{"type" => "crossfade"})
      {set, a, b}
    end

    test "a real fire far from the derived point persists, broadcasts, and wins the hint" do
      {set, a, b} = connected_pair()
      Sets.subscribe_set(set.id)

      # 120s is under the 70% trust floor (140s) — a MARKER there would be
      # distrusted, but the human fired there, so the hint honors it.
      assert {:ok, 120_000} = Sets.learn_fire_point(set.id, b.id, a.id, 120_000)
      assert_receive {:set_changed, _}

      entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
      assert entry_b.transition["learned_from_ms"] == 120_000

      hint = Sets.entry_after(set.id, a.id)
      assert hint.transition["from_ms"] == 120_000
      assert hint.transition["to_ms"] == 4_000
    end

    test "a fire within 5s of what the console would already do is noise, not a lesson" do
      {set, a, b} = connected_pair()

      assert :ignored = Sets.learn_fire_point(set.id, b.id, a.id, 182_000)
      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 180_000
    end

    test "front-half fires, wrong predecessors, and disabled pairs teach nothing" do
      {set, a, b} = connected_pair()

      # front half = a skip, not a mix-out
      assert :ignored = Sets.learn_fire_point(set.id, b.id, a.id, 80_000)
      # b does not precede a; a stranger in the from slot is stale UI
      assert :ignored = Sets.learn_fire_point(set.id, a.id, b.id, 120_000)
      stranger = insert(:track, status: :present)
      assert :ignored = Sets.learn_fire_point(set.id, b.id, stranger.id, 120_000)

      {:ok, _} = Sets.connect(set, b, %{"enabled" => false, "type" => "cut"})
      assert :ignored = Sets.learn_fire_point(set.id, b.id, a.id, 120_000)
    end

    test "a learned point hugging the end is clamped to keep the minimum tail" do
      {set, a, b} = connected_pair()

      assert {:ok, 199_000} = Sets.learn_fire_point(set.id, b.id, a.id, 199_000)
      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 197_000
    end

    test "re-deciding the pair wipes the learning — a fresh decision restarts from markers" do
      {set, a, b} = connected_pair()
      {:ok, _} = Sets.learn_fire_point(set.id, b.id, a.id, 120_000)

      {:ok, _} = Sets.connect(set, b, %{"type" => "cut"})

      entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
      refute Map.has_key?(entry_b.transition, "learned_from_ms")
      assert Sets.entry_after(set.id, a.id).transition["from_ms"] == 180_000
    end

    test "pair_timing exposes the learned point with the learned? badge" do
      {set, a, b} = connected_pair()

      entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
      assert Sets.pair_timing(a, entry_b) == %{from_ms: 180_000, to_ms: 4_000, learned?: false}

      {:ok, _} = Sets.learn_fire_point(set.id, b.id, a.id, 120_000)
      entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
      assert Sets.pair_timing(a, entry_b) == %{from_ms: 120_000, to_ms: 4_000, learned?: true}
    end
  end
end
