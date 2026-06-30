defmodule Beatgrid.MarkersTest do
  use Beatgrid.DataCase, async: true

  import Beatgrid.Factory
  import Mox

  setup :verify_on_exit!

  alias Beatgrid.Library.{Marker, Tracks}

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
end
