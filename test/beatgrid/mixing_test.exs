defmodule Beatgrid.MixingTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Mixing

  defp track_with(camelot, bpm, energy \\ 0.5) do
    song = insert(:soundcharts_song, camelot: camelot, tempo_bpm: bpm, energy: energy)
    insert(:track, soundcharts_song_id: song.id)
  end

  describe "suggest_next/2" do
    test "ranks harmonically compatible tracks within BPM tolerance, best first" do
      current = track_with("8A", 120.0, 0.6)
      same = track_with("8A", 121.0, 0.6)
      relative = track_with("8B", 122.0, 0.6)
      neighbor = track_with("9A", 124.0, 0.6)
      _wrong_key = track_with("3A", 120.0, 0.6)
      _far_bpm = track_with("8A", 150.0, 0.6)
      _unresolved = insert(:track)

      ids = current |> Mixing.suggest_next(limit: 10) |> Enum.map(& &1.track.id)

      assert same.id in ids
      assert relative.id in ids
      assert neighbor.id in ids
      refute current.id in ids
      # wrong key, far BPM and unresolved are excluded
      assert length(ids) == 3
      # same key + closest BPM ranks first; the ±1 neighbor last
      assert hd(ids) == same.id
      assert List.last(ids) == neighbor.id
    end

    test "respects the limit" do
      current = track_with("8A", 120.0)
      for _ <- 1..5, do: track_with("8A", 120.0)

      assert length(Mixing.suggest_next(current, limit: 2)) == 2
    end

    test "returns [] when the track has no resolved song" do
      assert Mixing.suggest_next(insert(:track)) == []
    end
  end
end
