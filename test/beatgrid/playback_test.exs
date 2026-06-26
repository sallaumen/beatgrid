defmodule Beatgrid.PlaybackTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Playback

  describe "preview_offset_ms/0" do
    test "returns the configured start offset in milliseconds" do
      assert Playback.preview_offset_ms() == 20_000
    end
  end

  describe "preview_min_duration_ms/0" do
    test "returns the minimum track length for the preview jump" do
      assert Playback.preview_min_duration_ms() == 25_000
    end
  end
end
