defmodule Beatgrid.Audio.MarkerDetectorCliTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.MarkerDetectorCli

  @fixture Path.expand(Path.join([__DIR__, "..", "..", "support", "fixtures", "sample.mp3"]))

  describe "parse/1" do
    test "takes the last markers line, ignoring progress lines" do
      output = """
      {"progress": {"stage": "decoding", "done": 1, "total": 1}}
      {"progress": {"stage": "structure", "done": 1, "total": 1}}
      {"markers": {"intro_ms": 1200, "outro_ms": 150000, "beat_ms": 500, "bpm": 120.0, "sections": [30000]}}
      """

      assert {:ok, detection} = MarkerDetectorCli.parse(output)
      assert detection.intro_ms == 1200
      assert detection.outro_ms == 150_000
      assert detection.sections == [30_000]
    end

    test "errors when no markers line exists" do
      assert {:error, {:no_markers, _}} = MarkerDetectorCli.parse("garbage\n")
    end
  end

  # `:librosa`-tagged: runs the real python+librosa v2 script; excluded by
  # default. The fixture is a ~1s clip — no beat grid, no structure — so this
  # pins the graceful-degrade path: the full shape comes back, never a crash.
  @tag :librosa
  test "analyzes a real (tiny) mp3 via the v2 script without crashing" do
    assert {:ok, detection} = MarkerDetectorCli.detect(@fixture)
    assert Map.has_key?(detection, :intro_ms)
    assert Map.has_key?(detection, :outro_ms)
    assert is_list(detection.sections)
  end
end
