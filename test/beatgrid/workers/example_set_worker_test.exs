defmodule Beatgrid.Workers.ExampleSetWorkerTest do
  use Beatgrid.DataCase, async: true, oban: true

  alias Beatgrid.Audio.MarkerDetectorMock
  alias Beatgrid.Sets
  alias Beatgrid.Workers.ExampleSetWorker

  test "builds a roots set, detects markers per track, and connects the pairs" do
    for i <- 1..4 do
      insert(:track,
        status: :present,
        genre_folder: "forro_roots",
        rel_path: "r#{i}.mp3",
        bpm_detected: 120.0 + i,
        tag_title: "R#{i}"
      )
    end

    stub(MarkerDetectorMock, :detect, fn _path ->
      {:ok, %{intro_ms: 4_000, outro_ms: 100_000, beat_ms: 500, bpm: 120.0, sections: []}}
    end)

    assert :ok = perform_job(ExampleSetWorker, %{})

    set = Enum.find(Sets.list(), &(&1.name == "Roots — exemplo"))
    assert set
    entries = Sets.entries(set)
    assert length(entries) >= 2

    # Auto markers were written on the tracks…
    [first_entry | _] = entries
    assert Enum.any?(first_entry.track.cue_points, &(&1["type"] == "intro"))
    # …and the consecutive pairs got connected.
    assert Enum.any?(tl(entries), &(&1.transition && &1.transition["enabled"]))
  end

  test "cancels when forro_roots has no present tracks" do
    assert {:cancel, :no_roots_tracks} = perform_job(ExampleSetWorker, %{})
  end
end
