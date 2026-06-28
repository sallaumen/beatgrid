defmodule Beatgrid.Workers.MixAnalyzeWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true

  import Beatgrid.Factory
  import Mox

  setup :verify_on_exit!
  setup :set_mox_global

  alias Beatgrid.Library.Normalize
  alias Beatgrid.Mixes
  alias Beatgrid.Workers.{MixAnalyzeWorker, MixCleanupWorker}

  test "uses description timestamps as boundaries, analyzes, names, matches, and readies" do
    track =
      insert(:track,
        status: :present,
        tag_artist: "A",
        tag_title: "One",
        norm_artist: Normalize.normalize("A"),
        norm_title: Normalize.normalize("One")
      )

    mix =
      insert(:mix,
        status: :analyzing,
        audio_path: "/tmp/_Mixes/m.mp3",
        description: "00:00 A - One\n04:30 B - Two"
      )

    expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "tracklist" => [
           %{"position" => 0, "start_seconds" => 0, "artist" => "A", "title" => "One"},
           %{"position" => 1, "start_seconds" => 270, "artist" => "B", "title" => "Two"}
         ]
       }}
    end)

    expect(Beatgrid.Audio.SetSegmenterMock, :analyze, fn "/tmp/_Mixes/m.mp3", [0, 270_000] ->
      {:ok,
       [
         %{start_ms: 0, end_ms: 270_000, bpm: 124.0, key: 7, mode: 1},
         %{start_ms: 270_000, end_ms: 600_000, bpm: 126.0, key: 2, mode: 1}
       ]}
    end)

    assert :ok = perform_job(MixAnalyzeWorker, %{mix_id: mix.id})

    reloaded = Mixes.get_with_segments(mix.id)
    assert reloaded.status == :ready
    assert [s1, s2] = reloaded.segments
    assert s1.artist == "A" and s1.title == "One"
    assert s1.bpm_detected == 124.0 and s1.camelot_detected != nil
    assert s1.matched_track_id == track.id
    assert s2.matched_track_id == nil
    assert_enqueued(worker: MixCleanupWorker, args: %{mix_id: mix.id})
  end
end
