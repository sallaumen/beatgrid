defmodule Beatgrid.MixingTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Mixing

  defp sc_track(attrs) do
    {song_attrs, track_attrs} = Keyword.split(attrs, [:camelot, :tempo_bpm, :energy])

    song =
      insert(
        :soundcharts_song,
        Keyword.merge([camelot: "8A", tempo_bpm: 120.0, energy: 0.5], song_attrs)
      )

    insert(:track, Keyword.merge([soundcharts_song_id: song.id, status: :present], track_attrs))
  end

  describe "config exposed to the UI" do
    test "weights/0 puts style and harmony above the rest" do
      w = Mixing.weights()
      assert w.style >= w.harmony
      assert w.harmony > w.intensity
      assert w.bpm > 0 and w.rating > 0
    end

    test "sections/0 lists the energy arc, peak being the most intense" do
      sections = Mixing.sections()
      pico = Enum.find(sections, &(&1.key == "pico"))
      abertura = Enum.find(sections, &(&1.key == "abertura"))
      assert pico.target_intensity == 0.95
      assert abertura.target_intensity > 0.5
      assert pico.target_intensity > abertura.target_intensity
    end
  end

  describe "intensity/1" do
    test "uses Soundcharts energy when present" do
      assert Mixing.intensity(sc_track(energy: 0.9)) == 0.9
    end

    test "falls back to a BPM proxy when only local analysis exists" do
      local =
        insert(:track, soundcharts_song_id: nil, bpm_detected: 160.0, camelot_detected: "8A")

      # (160 - 90) / 70 = 1.0
      assert Mixing.intensity(local) == 1.0
    end
  end

  describe "harmony/2" do
    test "grades from same key down to distant, neutral when unknown" do
      assert Mixing.harmony("8A", "8A") == 1.0
      assert Mixing.harmony("8A", "9A") == 0.8
      assert Mixing.harmony("8A", "8B") == 0.8
      assert Mixing.harmony("8A", "10A") == 0.4
      assert Mixing.harmony("8A", "3A") == 0.1
      assert Mixing.harmony(nil, "8A") == 0.5
    end
  end

  describe "rank/1" do
    test "style affinity orders candidates relative to the set's target style" do
      compatible = sc_track(energy: 0.7) |> set_folder("forro_classico")
      incompatible = sc_track(energy: 0.7) |> set_folder("mpb")

      ids =
        Mixing.rank(target_style: "forro_roots", limit: 10) |> Enum.map(& &1.track.id)

      assert Enum.find_index(ids, &(&1 == compatible.id)) <
               Enum.find_index(ids, &(&1 == incompatible.id))
    end

    test "intensity target pulls the right-energy track to the top of a section" do
      peak = sc_track(energy: 0.95)
      chill = sc_track(energy: 0.30)

      ids = Mixing.rank(target_intensity: 0.95, limit: 10) |> Enum.map(& &1.track.id)
      assert Enum.find_index(ids, &(&1 == peak.id)) < Enum.find_index(ids, &(&1 == chill.id))
    end

    test "opening (no previous track) ranks without harmony and never crashes" do
      a = sc_track(energy: 0.7)
      result = Mixing.rank(prev: nil, target_intensity: 0.70, limit: 5)
      assert a.id in Enum.map(result, & &1.track.id)
      assert %{breakdown: %{style: _, harmony: _, intensity: _, bpm: _}} = hd(result)
    end

    test "harmony is soft: still returns candidates with no neighbor of the previous key" do
      prev = sc_track(camelot: "8A")
      far = sc_track(camelot: "3B")

      ids = Mixing.rank(prev: prev, exclude: [prev.id], limit: 10) |> Enum.map(& &1.track.id)
      assert far.id in ids
    end

    test "respects :exclude and :limit" do
      keep = sc_track([])
      skip = sc_track([])
      for _ <- 1..5, do: sc_track([])

      ids = Mixing.rank(exclude: [skip.id], limit: 3) |> Enum.map(& &1.track.id)
      assert keep.id not in [skip.id]
      refute skip.id in ids
      assert length(ids) == 3
    end

    test "weights override re-orders candidates (bpm-heavy surfaces the bpm-closest track)" do
      prev = sc_track(camelot: "8A", tempo_bpm: 120.0, tag_title: "Prev")
      bpm_match = sc_track(camelot: "11A", tempo_bpm: 121.0, tag_title: "BpmMatch")
      key_match = sc_track(camelot: "8A", tempo_bpm: 150.0, tag_title: "KeyMatch")

      bpm_heavy = %{style: 0, harmony: 0, intensity: 0, bpm: 100, rating: 0}

      ids =
        Mixing.rank(prev: prev, weights: bpm_heavy, exclude: [prev.id], limit: 10)
        |> Enum.map(& &1.track.id)

      assert Enum.find_index(ids, &(&1 == bpm_match.id)) <
               Enum.find_index(ids, &(&1 == key_match.id))
    end

    test "default weights (no :weights opt) reproduce the harmony-led order" do
      prev = sc_track(camelot: "8A", tempo_bpm: 120.0, tag_title: "Prev")
      bpm_match = sc_track(camelot: "11A", tempo_bpm: 121.0, tag_title: "BpmMatch2")
      key_match = sc_track(camelot: "8A", tempo_bpm: 150.0, tag_title: "KeyMatch2")

      ids =
        Mixing.rank(prev: prev, exclude: [prev.id], limit: 10) |> Enum.map(& &1.track.id)

      assert Enum.find_index(ids, &(&1 == key_match.id)) <
               Enum.find_index(ids, &(&1 == bpm_match.id))
    end

    test "clamp_weights coerces strings, drops negatives/unknowns, fills missing from defaults" do
      assert %{style: 12.0, harmony: 30, bpm: 8} =
               Mixing.clamp_weights(%{style: "12", harmony: -5})

      assert Mixing.clamp_weights(nil) == Mixing.weights()
    end
  end

  describe "rank/1 filters" do
    test "harmonic_only keeps only key-compatible candidates" do
      prev = sc_track(camelot: "8A", tempo_bpm: 120.0, tag_title: "P")
      compat = sc_track(camelot: "8A", tempo_bpm: 120.0, tag_title: "Compat")
      far = sc_track(camelot: "3B", tempo_bpm: 120.0, tag_title: "Far")

      ids =
        Mixing.rank(prev: prev, harmonic_only: true, exclude: [prev.id], limit: 50)
        |> Enum.map(& &1.track.id)

      assert compat.id in ids
      refute far.id in ids
    end

    test "bpm_min/bpm_max bound the pool by effective bpm" do
      in_range = sc_track(camelot: "8A", tempo_bpm: 122.0, tag_title: "InRange")
      too_fast = sc_track(camelot: "8A", tempo_bpm: 150.0, tag_title: "TooFast")

      ids = Mixing.rank(bpm_min: 110, bpm_max: 130, limit: 50) |> Enum.map(& &1.track.id)
      assert in_range.id in ids
      refute too_fast.id in ids
    end

    test "min_rating and exclude_styles drop tracks" do
      keep =
        sc_track(camelot: "8A", tempo_bpm: 120.0, tag_title: "Keep", rating: 9)
        |> set_folder("forro")

      low =
        sc_track(camelot: "8A", tempo_bpm: 120.0, tag_title: "Low", rating: 2)
        |> set_folder("forro")

      banned =
        sc_track(camelot: "8A", tempo_bpm: 120.0, tag_title: "Banned", rating: 9)
        |> set_folder("mpb")

      ids =
        Mixing.rank(min_rating: 7, exclude_styles: ["mpb"], limit: 50) |> Enum.map(& &1.track.id)

      assert keep.id in ids
      refute low.id in ids
      refute banned.id in ids
    end
  end

  defp set_folder(track, folder) do
    {:ok, t} = Tracks.update(track, %{genre_folder: folder})
    t
  end
end
