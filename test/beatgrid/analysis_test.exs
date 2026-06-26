defmodule Beatgrid.AnalysisTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Analysis
  alias Beatgrid.Audio.AnalyzerMock
  alias Beatgrid.Library.Tracks

  test "analyze_track stores the detected bpm + camelot (key 9 minor → 8A)" do
    track = insert(:track, rel_path: "MPB/x.mp3")
    expect(AnalyzerMock, :analyze, fn _path -> {:ok, %{bpm: 92.5, key: 9, mode: 0}} end)

    assert {:ok, t} = Analysis.analyze_track(track)
    assert t.bpm_detected == 92.5
    assert t.camelot_detected == "8A"
    assert t.analyzed_at
  end

  test "propagates an analyzer error and stores nothing" do
    track = insert(:track)
    expect(AnalyzerMock, :analyze, fn _path -> {:error, :boom} end)

    assert {:error, :boom} = Analysis.analyze_track(track)
    assert is_nil(Tracks.get(track.id).bpm_detected)
  end
end
