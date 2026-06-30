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

  test "next_after returns the next ordered track and is reorder-safe (the set pointer)" do
    {:ok, set} = Sets.create("Chain")
    a = track_with("8A", 120.0)
    b = track_with("8A", 121.0)
    c = track_with("9A", 122.0)
    {:ok, _} = Sets.append(set, a)
    {:ok, _} = Sets.append(set, b)
    {:ok, _} = Sets.append(set, c)

    assert Sets.next_after(set, a.id).id == b.id
    assert Sets.next_after(set, b.id).id == c.id
    assert Sets.next_after(set, c.id) == nil
    assert Sets.next_after(set, "not-a-member") == nil

    # Reorder (c up → a, c, b): next_after reflects the new order with no re-sync.
    :ok = Sets.move(set, c, :up)
    assert Sets.next_after(set, a.id).id == c.id
    assert Sets.next_after(set, c.id).id == b.id

    # Accepts a raw set id too (what the player holds).
    assert Sets.next_after(set.id, a.id).id == c.id
  end

  test "first_track returns the opening track or nil when empty" do
    {:ok, set} = Sets.create("First")
    assert Sets.first_track(set) == nil

    a = track_with("8A", 120.0)
    b = track_with("8A", 121.0)
    {:ok, _} = Sets.append(set, a)
    {:ok, _} = Sets.append(set, b)

    assert Sets.first_track(set).id == a.id
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

  test "next_candidates threads weights + filters into the ranking" do
    {:ok, set} = Sets.create("Console")
    prev = track_with("8A", 120.0)
    {:ok, _} = Sets.append(set, prev)
    bpm_match = track_with("11A", 121.0)
    key_match = track_with("8A", 150.0)

    ids =
      Sets.next_candidates(set,
        weights: %{style: 0, harmony: 0, intensity: 0, bpm: 100, rating: 0},
        bpm_min: 110,
        bpm_max: 130,
        limit: 10
      )
      |> Enum.map(& &1.track.id)

    assert bpm_match.id in ids
    refute key_match.id in ids
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

  test "set_target_style anchors the set's style" do
    {:ok, set} = Sets.create("Roots")
    assert {:ok, set} = Sets.set_target_style(set, "forro_roots")
    assert Sets.get(set.id).target_style == "forro_roots"
  end

  test "suggest_opening ranks tracks for an empty set without a previous track" do
    {:ok, set} = Sets.create("Opener")
    a = track_with("8A", 120.0)

    ids = set |> Sets.suggest_opening(limit: 5) |> Enum.map(& &1.track.id)
    assert a.id in ids
  end

  test "fill_section appends N tracks tagged with the role, excluding members" do
    {:ok, set} = Sets.create("Pico")
    seed = track_with("8A", 120.0)
    track_with("8A", 120.5)
    track_with("8A", 121.0)
    {:ok, _} = Sets.append(set, seed)

    {:ok, _} = Sets.fill_section(set, "pico", 2)

    entries = Sets.entries(set)
    assert length(entries) == 3
    appended = Enum.filter(entries, &(&1.track.id != seed.id))
    assert length(appended) == 2
    assert Enum.all?(appended, &(&1.role == "pico"))
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

  test "plan_set builds an arc-shaped, fully-connected set of the requested size" do
    {:ok, set} = Sets.create("Planned")
    {:ok, set} = Sets.set_target_style(set, "forro_roots")

    # Plenty of candidates so no slot runs dry; varied BPM/key + intro/outro
    # markers so connections become real DJ transitions.
    for i <- 0..19 do
      track_with("8A", 118.0 + i,
        genre_folder: "forro_roots",
        cue_points: [
          %{"ms" => 2_000, "type" => "intro", "source" => "auto"},
          %{"ms" => 150_000, "type" => "outro", "source" => "auto"}
        ]
      )
    end

    assert {:ok, _set} = Sets.plan_set(set, 12)

    entries = Sets.entries(set)
    assert length(entries) == 12
    assert hd(entries).role == "abertura"
    assert List.last(entries).role == "queda"
    assert Enum.all?(entries, &(&1.role in ~w(abertura pico respiro queda)))
    # Every consecutive pair is connected.
    assert Enum.all?(tl(entries), &(&1.transition && &1.transition["enabled"]))
  end

  test "arc_series returns energy + bpm + role per entry, in order" do
    {:ok, set} = Sets.create("Arc")
    s1 = insert(:soundcharts_song, camelot: "8A", tempo_bpm: 120.0, energy: 0.9)
    s2 = insert(:soundcharts_song, camelot: "8A", tempo_bpm: 100.0, energy: 0.3)
    t1 = insert(:track, soundcharts_song_id: s1.id, status: :present)
    t2 = insert(:track, soundcharts_song_id: s2.id, status: :present)
    {:ok, _} = Sets.append(set, t1, "pico")
    {:ok, _} = Sets.append(set, t2, "respiro")

    assert [
             %{role: "pico", energy: e1, bpm: 120.0},
             %{role: "respiro", energy: e2, bpm: 100.0}
           ] = Sets.arc_series(set)

    assert_in_delta e1, 0.9, 0.001
    assert_in_delta e2, 0.3, 0.001
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
