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

  test "download_args resumes partial downloads and survives flaky networks" do
    args = FfmpegCli.download_args("https://youtu.be/x", "/tmp/d")
    assert List.last(args) == "https://youtu.be/x"
    # resume a partial file instead of restarting the multi-GB download
    assert "--continue" in args
    # don't hang forever on a stalled socket; retry transient failures
    assert "--socket-timeout" in args
    assert "--retries" in args
    # still a low-res, single-video download into the deterministic output template
    assert Enum.any?(args, &String.contains?(&1, "height<=720"))
    assert "--no-playlist" in args
    assert Enum.any?(args, &String.contains?(&1, "video.%(ext)s"))
  end
end
