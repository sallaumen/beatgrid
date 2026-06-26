defmodule Beatgrid.PlaybackTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Playback

  test "preview_offset_ms is the start offset for a preview play" do
    assert Playback.preview_offset_ms() == 20_000
  end

  test "preview_min_duration_ms is the minimum track length for the preview jump" do
    assert Playback.preview_min_duration_ms() == 25_000
  end
end
