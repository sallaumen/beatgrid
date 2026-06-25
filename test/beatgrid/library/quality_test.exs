defmodule Beatgrid.Library.QualityTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library.Quality

  defp meta(overrides) do
    {:ok,
     struct(
       %Metadata{title: "T", artist: "A", bitrate_kbps: 320, duration_ms: 200_000},
       overrides
     )}
  end

  describe "detect/1" do
    test "flags a file with no audio stream as :not_audio" do
      assert Quality.detect({:error, :not_audio}) == [:not_audio]
    end

    test "flags an unreadable file as :corrupt" do
      assert Quality.detect({:error, :ffprobe_failed}) == [:corrupt]
      assert Quality.detect({:error, :anything_else}) == [:corrupt]
    end

    test "a healthy, well-tagged track has no issues" do
      assert Quality.detect(meta(%{})) == []
    end

    test "flags missing title or artist as :missing_tags" do
      assert Quality.detect(meta(%{title: nil})) == [:missing_tags]
      assert Quality.detect(meta(%{artist: "  "})) == [:missing_tags]
    end

    test "flags a low bitrate" do
      assert Quality.detect(meta(%{bitrate_kbps: 96})) == [:low_bitrate]
    end

    test "flags a very short duration" do
      assert Quality.detect(meta(%{duration_ms: 5_000})) == [:too_short]
    end

    test "reports multiple issues in a stable order" do
      issues = Quality.detect(meta(%{title: nil, bitrate_kbps: 96, duration_ms: 5_000}))
      assert issues == [:missing_tags, :low_bitrate, :too_short]
    end
  end
end
