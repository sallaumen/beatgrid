defmodule Beatgrid.Workers.MixAnalyzeWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true

  import Beatgrid.Factory
  import Mox

  setup :verify_on_exit!
  setup :set_mox_global

  alias Beatgrid.Library.Normalize
  alias Beatgrid.Mixes
  alias Beatgrid.Workers.MixAnalyzeWorker

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

    expect(Beatgrid.Audio.SetSegmenterMock, :analyze, fn "/tmp/_Mixes/m.mp3",
                                                         [0, 270_000],
                                                         _opts ->
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
    # no more 24h auto-delete: analysis must NOT schedule any audio cleanup
    assert Mixes.get_mix(mix.id).cleanup_job_id == nil
  end

  test "uses chapters as track boundaries when there is no description tracklist" do
    mix =
      insert(:mix,
        status: :analyzing,
        audio_path: "/tmp/_Mixes/cap.mp3",
        description: "",
        chapters: [%{"start_ms" => 0, "title" => "A"}, %{"start_ms" => 120_000, "title" => "B"}],
        chapters_role: :tracks
      )

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"tracklist" => []}} end)

    expect(Beatgrid.Audio.SetSegmenterMock, :analyze, fn "/tmp/_Mixes/cap.mp3",
                                                         [0, 120_000],
                                                         _opts ->
      {:ok, [%{start_ms: 0, end_ms: 120_000, bpm: 120.0, key: 7, mode: 1}]}
    end)

    assert :ok = perform_job(MixAnalyzeWorker, %{mix_id: mix.id})
  end

  test "ignores chapters for boundaries when chapters_role is :djs" do
    mix =
      insert(:mix,
        status: :analyzing,
        audio_path: "/tmp/_Mixes/djs.mp3",
        description: "",
        chapters: [
          %{"start_ms" => 0, "title" => "DJ A"},
          %{"start_ms" => 120_000, "title" => "DJ B"}
        ],
        chapters_role: :djs
      )

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"tracklist" => []}} end)

    expect(Beatgrid.Audio.SetSegmenterMock, :analyze, fn "/tmp/_Mixes/djs.mp3", [], _opts ->
      {:ok, []}
    end)

    assert :ok = perform_job(MixAnalyzeWorker, %{mix_id: mix.id})
  end

  test "Path A: unnamed intro segment when first track starts at non-zero time" do
    mix =
      insert(:mix,
        status: :analyzing,
        audio_path: "/tmp/_Mixes/intro-test.mp3",
        description: "00:30 A - One\n05:00 B - Two"
      )

    expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "tracklist" => [
           %{"position" => 0, "start_seconds" => 30, "artist" => "A", "title" => "One"},
           %{"position" => 1, "start_seconds" => 300, "artist" => "B", "title" => "Two"}
         ]
       }}
    end)

    expect(Beatgrid.Audio.SetSegmenterMock, :analyze, fn "/tmp/_Mixes/intro-test.mp3",
                                                         [30_000, 300_000],
                                                         _opts ->
      {:ok,
       [
         %{start_ms: 0, end_ms: 30_000, bpm: 120.0, key: 1, mode: 1},
         %{start_ms: 30_000, end_ms: 300_000, bpm: 124.0, key: 7, mode: 1},
         %{start_ms: 300_000, end_ms: 600_000, bpm: 126.0, key: 2, mode: 1}
       ]}
    end)

    assert :ok = perform_job(MixAnalyzeWorker, %{mix_id: mix.id})

    reloaded = Mixes.get_with_segments(mix.id)
    assert reloaded.status == :ready
    assert [intro, seg1, seg2] = reloaded.segments

    assert intro.start_ms == 0
    assert intro.artist == nil
    assert intro.title == nil
    assert intro.name_source == :audio

    assert seg1.start_ms == 30_000
    assert seg1.artist == "A"
    assert seg1.title == "One"
    assert seg1.name_source == :description

    assert seg2.start_ms == 300_000
    assert seg2.artist == "B"
    assert seg2.title == "Two"
    assert seg2.name_source == :description
  end

  test "free_djs: after analyzing, derives :audio dj parts from candidates" do
    mix =
      insert(:mix,
        status: :analyzing,
        audio_path: "/tmp/_Mixes/f.mp3",
        description: "",
        chapters: []
      )

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"tracklist" => []}} end)

    expect(Beatgrid.Audio.SetSegmenterMock, :analyze, fn _p, _b, _opts ->
      {:ok,
       [
         %{start_ms: 0, end_ms: 120_000, bpm: 124.0, key: 7, mode: 1},
         %{start_ms: 120_000, end_ms: 300_000, bpm: 126.0, key: 2, mode: 1}
       ]}
    end)

    expect(Beatgrid.Audio.SetSegmenterMock, :dj_candidates, fn "/tmp/_Mixes/f.mp3" ->
      {:ok, [%{start_ms: 120_000, strength: 0.9}]}
    end)

    assert :ok = perform_job(MixAnalyzeWorker, %{mix_id: mix.id, free_djs: true})
    parts = Mixes.get_with_dj_parts(mix.id).dj_parts
    assert parts != [] and Enum.all?(parts, &(&1.source == :audio))
  end

  test "broadcasts per-segment progress" do
    Mixes.subscribe()
    mix = insert(:mix, status: :analyzing, audio_path: "/tmp/_Mixes/p.mp3", description: "")
    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"tracklist" => []}} end)

    expect(Beatgrid.Audio.SetSegmenterMock, :analyze, fn _p, _b, opts ->
      opts[:on_progress].(%{stage: "segments", done: 1, total: 1})
      {:ok, [%{start_ms: 0, end_ms: 1000, bpm: 120.0, key: 7, mode: 1}]}
    end)

    assert :ok = perform_job(MixAnalyzeWorker, %{mix_id: mix.id})
    assert_received {:mix_progress, %{stage: "segments", done: 1, total: 1, mix_id: _}}
  end
end
