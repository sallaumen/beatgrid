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

    test "echo-out when markers exist but BPMs diverge (the tail masks the tempo jump)" do
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

      assert Sets.suggest_transition(a, b)["type"] == "echo"
    end

    test "the transition vocabulary includes echo, in UI order" do
      assert Sets.transition_types() == ~w(cut fade crossfade echo)
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

      # the persisted outro sat mid-song (30s of 200s) — the hint clamps it to
      # the outgoing track's back half, away from the "salto no meio" bug
      assert hint.transition["type"] == "echo"
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
