defmodule Beatgrid.Workers.MixDjVisionWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true
  import Beatgrid.Factory
  import Mox
  setup :verify_on_exit!
  setup :set_mox_global

  alias Beatgrid.Mixes
  alias Beatgrid.Workers.MixDjVisionWorker

  test "samples frames sequentially, montages, OCRs, and writes :image dj parts" do
    # interval 4_000 → 2 frames from duration 8_000; tiles_per_grid 16 → one montage chunk
    prev = Application.get_env(:beatgrid, MixDjVisionWorker)
    Application.put_env(:beatgrid, MixDjVisionWorker, frame_interval_ms: 4_000, tiles_per_grid: 16)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:beatgrid, MixDjVisionWorker, prev),
        else: Application.delete_env(:beatgrid, MixDjVisionWorker)
    end)

    mix = insert(:mix, duration_ms: 8_000, source_url: "https://youtu.be/x")
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    insert(:mix_segment, mix: mix, position: 1, start_ms: 4_000)

    expect(Beatgrid.Video.FrameSamplerMock, :download_video, fn _url, dir ->
      {:ok, Path.join(dir, "video.mp4")}
    end)

    expect(Beatgrid.Video.FrameSamplerMock, :extract_frames, fn _video, %{dir: dir} ->
      {:ok, [Path.join(dir, "f00001.jpg"), Path.join(dir, "f00002.jpg")]}
    end)

    expect(Beatgrid.Video.FrameSamplerMock, :montage, fn _paths, dest -> {:ok, dest} end)

    # Vision returns names for 2 tiles: frame 0 → ts 0ms, frame 1 → ts 4000ms
    expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"names" => ["A", "B"]}} end)

    assert :ok = perform_job(MixDjVisionWorker, %{mix_id: mix.id})
    parts = Mixes.get_with_dj_parts(mix.id).dj_parts
    assert Enum.map(parts, & &1.dj_name) == ["A", "B"]
    assert Enum.all?(parts, &(&1.source == :image))
  end

  describe "resilience + coverage" do
    setup do
      prev = Application.get_env(:beatgrid, MixDjVisionWorker)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:beatgrid, MixDjVisionWorker, prev),
          else: Application.delete_env(:beatgrid, MixDjVisionWorker)
      end)

      :ok
    end

    test "is configured for long-job resilience: 10 attempts, 24h unique window on mix_id" do
      opts = MixDjVisionWorker.__opts__()
      assert opts[:max_attempts] == 10
      assert opts[:unique][:period] == 86_400
      assert opts[:unique][:keys] == [:mix_id]
    end

    test "defines a timeout below the Lifeline rescue window" do
      assert MixDjVisionWorker.timeout(%Oban.Job{}) == :timer.minutes(70)
    end

    test "work_dir is deterministic per mix (no per-run unique suffix)" do
      mix = insert(:mix)
      assert MixDjVisionWorker.work_dir(mix) ==
               Path.join(System.tmp_dir!(), "beatgrid-dj-vision-#{mix.id}")
    end

    test "over the failure threshold, returns {:error, {:partial_coverage,...}} and persists nothing" do
      Application.put_env(:beatgrid, MixDjVisionWorker,
        frame_interval_ms: 4_000,
        tiles_per_grid: 1,
        max_failure_ratio: 0.5
      )

      mix = insert(:mix, duration_ms: 16_000, source_url: "https://youtu.be/x")
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      on_exit(fn -> File.rm_rf(MixDjVisionWorker.work_dir(mix)) end)

      stub(Beatgrid.Video.FrameSamplerMock, :download_video, fn _u, dir ->
        {:ok, Path.join(dir, "video.mp4")}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :extract_frames, fn _v, %{dir: dir} ->
        {:ok, for(i <- 1..4, do: Path.join(dir, "f0000#{i}.jpg"))}
      end)

      # 4 grids (tiles_per_grid 1); only grid 0 montages, rest fail -> 3/4 = 75% > 50%
      stub(Beatgrid.Video.FrameSamplerMock, :montage, fn _p, dest ->
        if String.contains?(dest, "montage-0.jpg"),
          do: {:ok, dest},
          else: {:error, {:ffmpeg_exit, 254, "missing"}}
      end)

      stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"names" => ["A"]}} end)

      assert {:error, {:partial_coverage, 1, 4}} = perform_job(MixDjVisionWorker, %{mix_id: mix.id})
      assert Mixes.get_with_dj_parts(mix.id).dj_parts == []
    end

    test "under the failure threshold, persists covered grids and marks the uncovered tail no-DJ" do
      Application.put_env(:beatgrid, MixDjVisionWorker,
        frame_interval_ms: 4_000,
        tiles_per_grid: 1,
        max_failure_ratio: 0.9
      )

      mix = insert(:mix, duration_ms: 16_000, source_url: "https://youtu.be/x")
      for i <- 0..3, do: insert(:mix_segment, mix: mix, position: i, start_ms: i * 4_000)

      stub(Beatgrid.Video.FrameSamplerMock, :download_video, fn _u, dir ->
        {:ok, Path.join(dir, "video.mp4")}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :extract_frames, fn _v, %{dir: dir} ->
        {:ok, for(i <- 1..4, do: Path.join(dir, "f0000#{i}.jpg"))}
      end)

      # grids 0,1 ok (ts 0, 4000); grids 2,3 fail -> 2/4 = 50% < 90%
      stub(Beatgrid.Video.FrameSamplerMock, :montage, fn _p, dest ->
        if String.contains?(dest, "montage-0.jpg") or String.contains?(dest, "montage-1.jpg"),
          do: {:ok, dest},
          else: {:error, {:ffmpeg_exit, 254, "missing"}}
      end)

      stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"names" => ["A"]}} end)

      assert :ok = perform_job(MixDjVisionWorker, %{mix_id: mix.id})
      parts = Mixes.get_with_dj_parts(mix.id).dj_parts
      # coverage ended at grid 1 (ts 4000 + interval 4000 = 8000): a nil tail spans to duration
      assert Enum.any?(parts, &(&1.dj_name == nil and &1.end_ms == 16_000))
      assert Enum.any?(parts, & &1.dj_name)
    end

    test "reuses an already-downloaded video instead of downloading again" do
      Application.put_env(:beatgrid, MixDjVisionWorker, frame_interval_ms: 4_000, tiles_per_grid: 16)
      mix = insert(:mix, duration_ms: 8_000, source_url: "https://youtu.be/x")
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)

      dir = MixDjVisionWorker.work_dir(mix)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "video.mp4"), "x")
      on_exit(fn -> File.rm_rf(dir) end)

      # download_video must NOT be called (no stub) — the existing file is reused.
      stub(Beatgrid.Video.FrameSamplerMock, :extract_frames, fn _v, %{dir: d} ->
        {:ok, [Path.join(d, "f00001.jpg")]}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :montage, fn _p, dest -> {:ok, dest} end)
      stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"names" => ["A"]}} end)

      assert :ok = perform_job(MixDjVisionWorker, %{mix_id: mix.id})
    end

    test "a zero-frame extraction errors out without wiping existing dj parts" do
      Application.put_env(:beatgrid, MixDjVisionWorker, frame_interval_ms: 4_000, tiles_per_grid: 9)
      mix = insert(:mix, duration_ms: 16_000, source_url: "https://youtu.be/x")
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      # a previously-detected part that must NOT be wiped by a transient empty extraction
      insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 16_000, dj_name: "KEEP", source: :image)
      on_exit(fn -> File.rm_rf(MixDjVisionWorker.work_dir(mix)) end)

      stub(Beatgrid.Video.FrameSamplerMock, :download_video, fn _u, dir ->
        {:ok, Path.join(dir, "video.mp4")}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :extract_frames, fn _v, _o -> {:ok, []} end)

      assert {:error, :no_frames} = perform_job(MixDjVisionWorker, %{mix_id: mix.id})
      assert Enum.map(Mixes.get_with_dj_parts(mix.id).dj_parts, & &1.dj_name) == ["KEEP"]
    end

    test "the final failed attempt cleans up the work dir (no permanent multi-GB leak)" do
      Application.put_env(:beatgrid, MixDjVisionWorker,
        frame_interval_ms: 4_000,
        tiles_per_grid: 1,
        max_failure_ratio: 0.5
      )

      mix = insert(:mix, duration_ms: 16_000, source_url: "https://youtu.be/x")
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)

      stub(Beatgrid.Video.FrameSamplerMock, :download_video, fn _u, dir ->
        {:ok, Path.join(dir, "video.mp4")}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :extract_frames, fn _v, %{dir: dir} ->
        {:ok, for(i <- 1..4, do: Path.join(dir, "f0000#{i}.jpg"))}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :montage, fn _p, _d -> {:error, {:ffmpeg_exit, 254, "x"}} end)

      assert {:error, {:partial_coverage, 0, 4}} =
               perform_job(MixDjVisionWorker, %{mix_id: mix.id}, attempt: 10)

      refute File.dir?(MixDjVisionWorker.work_dir(mix))
    end

    test "a non-final failed attempt keeps the work dir for resume" do
      Application.put_env(:beatgrid, MixDjVisionWorker,
        frame_interval_ms: 4_000,
        tiles_per_grid: 1,
        max_failure_ratio: 0.5
      )

      mix = insert(:mix, duration_ms: 16_000, source_url: "https://youtu.be/x")
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      on_exit(fn -> File.rm_rf(MixDjVisionWorker.work_dir(mix)) end)

      stub(Beatgrid.Video.FrameSamplerMock, :download_video, fn _u, dir ->
        {:ok, Path.join(dir, "video.mp4")}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :extract_frames, fn _v, %{dir: dir} ->
        {:ok, for(i <- 1..4, do: Path.join(dir, "f0000#{i}.jpg"))}
      end)

      stub(Beatgrid.Video.FrameSamplerMock, :montage, fn _p, _d -> {:error, {:ffmpeg_exit, 254, "x"}} end)

      assert {:error, {:partial_coverage, 0, 4}} =
               perform_job(MixDjVisionWorker, %{mix_id: mix.id}, attempt: 1)

      assert File.dir?(MixDjVisionWorker.work_dir(mix))
    end
  end
end
