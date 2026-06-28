defmodule Beatgrid.Video.FrameSampler.FfmpegCliTest do
  use ExUnit.Case, async: true
  alias Beatgrid.Video.FrameSampler.FfmpegCli

  test "build_montage_args includes all input paths and dest, uses xstack for multiple frames" do
    args = FfmpegCli.build_montage_args(["/a.jpg", "/b.jpg"], "/tmp/m.jpg")
    assert "/tmp/m.jpg" == List.last(args)
    assert "-i" in args
    assert Enum.any?(args, &(&1 == "/a.jpg"))
    assert Enum.any?(args, &(&1 == "/b.jpg"))
    assert Enum.any?(args, &String.contains?(&1, "xstack"))
    refute Enum.any?(args, &String.contains?(&1, "drawtext"))
  end

  test "build_montage_args with a single frame does not use xstack and ends with dest" do
    args = FfmpegCli.build_montage_args(["/a.jpg"], "/tmp/m.jpg")
    assert "/tmp/m.jpg" == List.last(args)
    assert Enum.any?(args, &(&1 == "/a.jpg"))
    refute Enum.any?(args, &String.contains?(&1, "xstack"))
  end
end
