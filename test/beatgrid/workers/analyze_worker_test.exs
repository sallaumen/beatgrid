defmodule Beatgrid.Workers.AnalyzeWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  alias Beatgrid.Audio.AnalyzerMock
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Workers.AnalyzeWorker

  test "analyzes the referenced track and stores the detected values" do
    expect(AnalyzerMock, :analyze, fn _path -> {:ok, %{bpm: 90.0, key: 0, mode: 1}} end)
    track = insert(:track, status: :present)

    assert :ok = perform_job(AnalyzeWorker, %{"track_id" => track.id})

    reloaded = Tracks.get(track.id)
    assert reloaded.bpm_detected == 90.0
    assert reloaded.camelot_detected == "8B"
    assert reloaded.analyzed_at
  end

  test "cancels when the track no longer exists" do
    assert {:cancel, :track_not_found} =
             perform_job(AnalyzeWorker, %{"track_id" => Ecto.UUID.generate()})
  end
end
