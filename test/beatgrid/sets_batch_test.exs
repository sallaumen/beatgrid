defmodule Beatgrid.SetsBatchTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Sets

  defp rankable_track(n) do
    song = build(:soundcharts_song, camelot: "8A", tempo_bpm: 120.0, energy: 0.6)

    insert(:track,
      soundcharts_song: song,
      status: :present,
      genre_folder: "forro",
      tag_artist: "Artist #{n}",
      tag_title: "Song #{n}"
    )
  end

  defp filled_set(tracks) do
    {:ok, set} = Sets.create("Fila")
    for track <- tracks, do: {:ok, _} = Sets.append(set, track)
    set
  end

  describe "append/3 position integrity" do
    test "appending after a library deletion cascaded a hole keeps positions unique" do
      [a, b, c, d] = for n <- 1..4, do: rankable_track(n)
      set = filled_set([a, b, c])

      {:ok, _} = Tracks.delete(b)
      {:ok, _} = Sets.append(set, d)

      entries = Sets.entries(set)
      positions = Enum.map(entries, & &1.position)
      assert Enum.map(entries, & &1.track.id) == [a.id, c.id, d.id]
      assert positions == Enum.uniq(positions)
    end
  end

  describe "batch fills notify subscribers once" do
    setup do
      for n <- 1..12, do: rankable_track(n)
      {:ok, set} = Sets.create("Set")
      Sets.subscribe_set(set.id)
      %{set: set}
    end

    test "auto_fill/2", %{set: set} do
      {:ok, _} = Sets.auto_fill(set, count: 3)

      assert_receive {:set_changed, _}, 500
      refute_receive {:set_changed, _}, 100
      assert length(Sets.tracks(set)) == 3
    end

    test "fill_section/3", %{set: set} do
      {:ok, _} = Sets.fill_section(set, "pico", 3)

      assert_receive {:set_changed, _}, 500
      refute_receive {:set_changed, _}, 100
      assert Enum.all?(Sets.entries(set), &(&1.role == "pico"))
    end

    test "plan/2", %{set: set} do
      {:ok, _} = Sets.plan(set, %{"mode" => "tracks", "track_count" => "6"})

      assert_receive {:set_changed, _}, 2_000
      refute_receive {:set_changed, _}, 100
    end
  end

  test "extending connects only new boundaries and preserves manual and disconnected pairs" do
    [a, b, c, d] = for n <- 1..4, do: rankable_track(n)
    set = filled_set([a, b, c])
    {:ok, _} = Sets.connect(set, b, %{"type" => "fade", "breather" => false})
    before = Sets.entries(set)

    assert {:ok, _} = Sets.plan(set, %{"fill_mode" => "append", "track_count" => "2"})
    {original, [added]} = Enum.split(Sets.entries(set), 3)
    assert Enum.map(original, & &1.transition) == Enum.map(before, & &1.transition)
    assert added.track.id == d.id
    assert added.transition["enabled"]
  end

  test "a small candidate pool gets a complete energy arc even when more tracks were requested" do
    for n <- 1..4, do: rankable_track(n)
    {:ok, set} = Sets.create("Curto")

    assert {:ok, _} = Sets.plan(set, %{"mode" => "tracks", "track_count" => "80"})
    entries = Sets.entries(set)
    assert length(entries) == 4
    assert hd(entries).role == "abertura"
    assert List.last(entries).role == "queda"
  end

  describe "create_filled/2" do
    test "creates the set with the tracks in order and every pair connected" do
      tracks = for n <- 1..3, do: rankable_track(n)

      assert {:ok, set} = Sets.create_filled("Playlist do YouTube", tracks)

      entries = Sets.entries(set)
      assert set.name == "Playlist do YouTube"
      assert Enum.map(entries, & &1.track.id) == Enum.map(tracks, & &1.id)
      assert [nil | transitions] = Enum.map(entries, & &1.transition)
      assert Enum.all?(transitions, &is_map/1)
    end

    test "a failing row rolls the whole creation back" do
      ghost = build(:track, id: Uniq.UUID.uuid7(), status: :present)

      assert {:error, _} = Sets.create_filled("Meio a meio", [rankable_track(1), ghost])
      assert Sets.list() == []
    end

    test "an invalid name surfaces the changeset instead of raising" do
      assert {:error, %Ecto.Changeset{}} = Sets.create_filled(nil, [])
    end
  end

  describe "stale membership" do
    test "filling a deleted set returns a domain error without announcing a fill" do
      candidate = rankable_track(1)
      deleted = filled_set([])
      remaining = filled_set([])
      {:ok, _} = Sets.delete(deleted)
      Sets.subscribe_set(deleted.id)

      assert {:error, %Beatgrid.Error{code: :set_not_found}} = Sets.auto_fill(deleted, count: 1)

      assert {:error, %Beatgrid.Error{code: :set_not_found}} =
               Sets.fill_section(deleted, "pico", 1)

      assert Sets.list() |> Enum.map(& &1.id) == [remaining.id]
      assert Sets.entries(remaining) == []
      assert Tracks.get(candidate.id)
      refute_receive {:set_changed, _id}, 100
    end

    test "a live set with no candidates still completes either fill without changing its entries" do
      set = filled_set([])
      Sets.subscribe_set(set.id)

      assert {:ok, %{id: id}} = Sets.auto_fill(set, count: 1)
      assert id == set.id
      assert_receive {:set_changed, ^id}, 500
      refute_receive {:set_changed, ^id}, 100

      assert {:ok, %{id: ^id}} = Sets.fill_section(set, "pico", 1)
      assert_receive {:set_changed, ^id}, 500
      refute_receive {:set_changed, ^id}, 100
      assert Sets.entries(set) == []
    end

    test "send to bottom uses the actual order even after library deletions leave holes" do
      [a, b, c, d, e] = for n <- 1..5, do: rankable_track(n)
      set = filled_set([a, b, c, d, e])
      {:ok, _} = Tracks.delete(b)
      {:ok, _} = Tracks.delete(c)

      assert :ok = Sets.move(set, a, :bottom)

      assert Enum.map(Sets.entries(set), &{&1.track.id, &1.position}) ==
               [{d.id, 1}, {e.id, 2}, {a.id, 3}]

      assert :ok = Sets.remove(set, a)
      assert :ok = Sets.move(set, a, :top)
      assert Enum.map(Sets.tracks(set), & &1.id) == [d.id, e.id]
    end

    test "connect/3 on a track outside the set returns an error instead of raising" do
      [a, b] = for n <- 1..2, do: rankable_track(n)
      set = filled_set([a])

      assert {:error, :not_a_member} = Sets.connect(set, b, %{"type" => "fade"})
      assert {:error, :not_a_member} = Sets.disconnect(set, b)
    end
  end
end
