defmodule Beatgrid.Workers.MarkerAnalyzeWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  alias Beatgrid.Audio.MarkerDetectorMock
  alias Beatgrid.Library.{Marker, Tracks}
  alias Beatgrid.Workers.MarkerAnalyzeWorker

  test "detects and persists auto markers for the referenced track" do
    track = insert(:track, status: :present, rel_path: "x.mp3")

    expect(MarkerDetectorMock, :detect, fn _path ->
      {:ok, %{intro_ms: 1_000, outro_ms: 5_000, beat_ms: 500, bpm: 120.0, sections: []}}
    end)

    assert :ok = perform_job(MarkerAnalyzeWorker, %{"track_id" => track.id})

    cues = Tracks.get(track.id).cue_points
    intro = Enum.find(cues, &(&1["ms"] == 1_000))
    assert Marker.type(intro) == "intro"
    assert Marker.auto?(intro)
  end

  test "cancels for an unknown track" do
    assert {:cancel, :track_not_found} =
             perform_job(MarkerAnalyzeWorker, %{"track_id" => Ecto.UUID.generate()})
  end
end
