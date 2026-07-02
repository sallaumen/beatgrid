defmodule Beatgrid.MarkersTest do
  use Beatgrid.DataCase, async: true, oban: true

  import Beatgrid.Factory
  import Mox

  setup :verify_on_exit!

  alias Beatgrid.Library.{Marker, Tracks}
  alias Beatgrid.Markers
  alias Beatgrid.Workers.MarkerAnalyzeWorker

  defp auto(ms), do: %{"ms" => ms, "label" => nil, "type" => "intro", "source" => "auto"}
  defp manual(ms), do: %{"ms" => ms, "label" => "x", "type" => "cue", "source" => "manual"}

  test "detect writes intro/outro/section markers as auto, preserving manual ones" do
    track = insert(:track, status: :present, rel_path: "x.mp3")
    {:ok, track} = Tracks.add_marker(track, 40_000, "manual")

    expect(Beatgrid.Audio.MarkerDetectorMock, :detect, fn _path ->
      {:ok, %{intro_ms: 5_000, outro_ms: 90_000, beat_ms: 500, bpm: 120.0, sections: [30_000]}}
    end)

    {:ok, updated} = Beatgrid.Markers.detect(track)
    by_ms = Map.new(updated.cue_points, &{&1["ms"], &1})

    assert Marker.type(by_ms[5_000]) == "intro"
    assert Marker.auto?(by_ms[5_000])
    assert Marker.type(by_ms[90_000]) == "outro"
    assert Marker.type(by_ms[30_000]) == "cue"
    assert Marker.auto?(by_ms[30_000])

    # The pre-existing manual marker is untouched.
    assert by_ms[40_000]["label"] == "manual"
    refute Marker.auto?(by_ms[40_000])
  end

  test "detect surfaces the port error" do
    track = insert(:track, status: :present, rel_path: "x.mp3")

    expect(Beatgrid.Audio.MarkerDetectorMock, :detect, fn _path -> {:error, :boom} end)

    assert {:error, :boom} = Beatgrid.Markers.detect(track)
  end

  describe "bulk mapping" do
    test "unmapped_ids lists present tracks lacking any auto marker" do
      none = insert(:track, status: :present, rel_path: "a.mp3", cue_points: [])

      only_manual =
        insert(:track, status: :present, rel_path: "b.mp3", cue_points: [manual(1000)])

      with_auto = insert(:track, status: :present, rel_path: "c.mp3", cue_points: [auto(500)])
      absent = insert(:track, status: :quarantined, rel_path: "d.mp3", cue_points: [])

      ids = Markers.unmapped_ids()

      assert none.id in ids
      assert only_manual.id in ids
      refute with_auto.id in ids
      refute absent.id in ids
      assert Markers.unmapped_count() == length(ids)
    end

    test "enqueue_unmapped enqueues one MarkerAnalyzeWorker per unmapped track" do
      t_1 = insert(:track, status: :present, rel_path: "a.mp3", cue_points: [])
      t_2 = insert(:track, status: :present, rel_path: "b.mp3", cue_points: [manual(1000)])
      _mapped = insert(:track, status: :present, rel_path: "c.mp3", cue_points: [auto(500)])

      assert {:ok, 2} = Markers.enqueue_unmapped()

      assert_enqueued(worker: MarkerAnalyzeWorker, args: %{track_id: t_1.id})
      assert_enqueued(worker: MarkerAnalyzeWorker, args: %{track_id: t_2.id})
    end
  end
end
