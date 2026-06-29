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
end
