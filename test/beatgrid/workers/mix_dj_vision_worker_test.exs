defmodule Beatgrid.Workers.MixDjVisionWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true
  import Beatgrid.Factory
  import Mox
  setup :verify_on_exit!
  setup :set_mox_global

  alias Beatgrid.Mixes
  alias Beatgrid.Workers.MixDjVisionWorker

  test "samples grids, OCRs, and writes :image dj parts" do
    # duration_ms < frame_interval_ms (10_000) → exactly one window, one grid call
    mix = insert(:mix, duration_ms: 8_000, source_url: "https://youtu.be/x")
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    insert(:mix_segment, mix: mix, position: 1, start_ms: 4_000)

    expect(Beatgrid.Video.FrameSamplerMock, :resolve_stream, fn _ -> {:ok, "http://stream"} end)
    expect(Beatgrid.Video.FrameSamplerMock, :sample_grid, fn _u, %{dest: dest} -> {:ok, dest} end)

    expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok, %{"tiles" => [%{"ts_ms" => 0, "dj_name" => "A"}, %{"ts_ms" => 4_000, "dj_name" => "B"}]}}
    end)

    assert :ok = perform_job(MixDjVisionWorker, %{mix_id: mix.id})
    parts = Mixes.get_with_dj_parts(mix.id).dj_parts
    assert Enum.map(parts, & &1.dj_name) == ["A", "B"]
    assert Enum.all?(parts, &(&1.source == :image))
  end
end
