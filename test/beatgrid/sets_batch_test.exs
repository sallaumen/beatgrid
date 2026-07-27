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
    test "connect/3 on a track outside the set returns an error instead of raising" do
      [a, b] = for n <- 1..2, do: rankable_track(n)
      set = filled_set([a])

      assert {:error, :not_a_member} = Sets.connect(set, b, %{"type" => "fade"})
      assert {:error, :not_a_member} = Sets.disconnect(set, b)
    end
  end
end
