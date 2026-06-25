defmodule Beatgrid.SetsTest do
  # async: false — export_m3u/1 writes under the (overridden) library root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Sets

  setup tags do
    if root = tags[:tmp_dir] do
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  defp track_with(camelot, bpm, attrs \\ []) do
    song = insert(:soundcharts_song, camelot: camelot, tempo_bpm: bpm, energy: 0.5)
    insert(:track, Keyword.merge([soundcharts_song_id: song.id], attrs))
  end

  test "create, append in order, then remove with reindex" do
    {:ok, set} = Sets.create("Sunset")
    a = track_with("8A", 120.0)
    b = track_with("8A", 121.0)
    c = track_with("9A", 122.0)

    {:ok, _} = Sets.append(set, a)
    {:ok, _} = Sets.append(set, b)
    {:ok, _} = Sets.append(set, c)
    assert Enum.map(Sets.tracks(set), & &1.id) == [a.id, b.id, c.id]

    :ok = Sets.remove(set, b)
    assert Enum.map(Sets.tracks(set), & &1.id) == [a.id, c.id]

    assert [%{name: "Sunset"}] = Sets.list()
  end

  test "next_candidates suggests compatible tracks not already in the set" do
    {:ok, set} = Sets.create("X")
    seed = track_with("8A", 120.0)
    compat = track_with("8A", 120.5)
    {:ok, _} = Sets.append(set, seed)

    cand_ids = set |> Sets.next_candidates(limit: 10) |> Enum.map(& &1.track.id)
    assert compat.id in cand_ids
    refute seed.id in cand_ids

    {:ok, _} = Sets.append(set, compat)
    refute compat.id in (set |> Sets.next_candidates(limit: 10) |> Enum.map(& &1.track.id))
  end

  test "move reorders a track up and down, clamping at the edges" do
    {:ok, set} = Sets.create("Reorder")
    a = track_with("8A", 120.0)
    b = track_with("8A", 121.0)
    c = track_with("9A", 122.0)
    for t <- [a, b, c], do: Sets.append(set, t)

    ids = fn -> Enum.map(Sets.tracks(set), & &1.id) end

    :ok = Sets.move(set, b, :up)
    assert ids.() == [b.id, a.id, c.id]

    :ok = Sets.move(set, b, :down)
    assert ids.() == [a.id, b.id, c.id]

    # moving the first one up is a no-op
    :ok = Sets.move(set, a, :up)
    assert ids.() == [a.id, b.id, c.id]
  end

  test "auto_fill greedily extends the set harmonically" do
    {:ok, set} = Sets.create("Auto")
    seed = track_with("8A", 120.0)
    track_with("8A", 120.5)
    track_with("8A", 121.0)
    {:ok, _} = Sets.append(set, seed)

    {:ok, _} = Sets.auto_fill(set, count: 2)
    assert length(Sets.tracks(set)) == 3
  end

  @tag :tmp_dir
  test "export_m3u writes an .m3u with EXTINF + absolute paths under _Sets", %{tmp_dir: root} do
    {:ok, set} = Sets.create("My Set")

    t =
      track_with("8A", 120.0,
        rel_path: "MPB/song.mp3",
        filename: "song.mp3",
        tag_artist: "Jobim",
        tag_title: "Wave",
        duration_ms: 180_000
      )

    {:ok, _} = Sets.append(set, t)

    assert {:ok, path} = Sets.export_m3u(set)
    assert path == Path.join([root, "_Sets", "My Set.m3u"])

    body = File.read!(path)
    assert body =~ "#EXTM3U"
    assert body =~ "#EXTINF:180,Jobim - Wave"
    assert body =~ Path.join(root, "MPB/song.mp3")
  end
end
