defmodule Beatgrid.Video.FrameSampler.FfmpegCliTest do
  use ExUnit.Case, async: true
  alias Beatgrid.Video.FrameSampler.FfmpegCli

  test "build_grid_args seeks each tile and outputs the dest" do
    args = FfmpegCli.build_grid_args("http://stream", [0, 10_000], "/tmp/grid.jpg")
    assert "/tmp/grid.jpg" == List.last(args)
    assert Enum.any?(args, &(&1 == "http://stream"))
    assert "-ss" in args
    # No drawtext: not all ffmpeg builds ship libfreetype (tiles aligned by order, not burned text).
    refute Enum.any?(args, &String.contains?(&1, "drawtext"))
  end

  test "build_grid_args with a single tile does not use xstack and still ends with dest" do
    args = FfmpegCli.build_grid_args("http://stream", [5_000], "/tmp/single.jpg")
    assert "/tmp/single.jpg" == List.last(args)
    assert Enum.any?(args, &(&1 == "http://stream"))
    assert "-ss" in args
    refute Enum.any?(args, &String.contains?(&1, "xstack"))
  end
end
