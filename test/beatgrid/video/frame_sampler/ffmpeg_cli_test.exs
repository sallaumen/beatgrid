defmodule Beatgrid.Video.FrameSampler.FfmpegCliTest do
  use ExUnit.Case, async: true
  alias Beatgrid.Video.FrameSampler.FfmpegCli

  test "build_grid_args seeks each tile and outputs the dest" do
    args = FfmpegCli.build_grid_args("http://stream", [0, 10_000], "/tmp/grid.jpg")
    assert "/tmp/grid.jpg" == List.last(args)
    assert Enum.any?(args, &(&1 == "http://stream"))
    assert "-ss" in args
  end
end
