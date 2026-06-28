defmodule Beatgrid.Mixes.DjTimestampsTest do
  use ExUnit.Case, async: true
  alias Beatgrid.Mixes.DjTimestamps

  test "parses h:mm:ss, mm:ss with optional names" do
    text = """
    0:00 DJ A
    1:02:30 DJ B
    95:00
    """

    # 0:00    MM:SS → 0 ms
    # 1:02:30 H:MM:SS → (1*3600 + 2*60 + 30) = 3750 s = 3_750_000 ms
    # 95:00   MM:SS → 95*60 = 5700 s = 5_700_000 ms
    assert DjTimestamps.parse(text) == [
             %{start_ms: 0, dj_name: "DJ A"},
             %{start_ms: 3_750_000, dj_name: "DJ B"},
             %{start_ms: 5_700_000, dj_name: nil}
           ]
  end

  test "ignores blank/garbage lines and sorts" do
    assert DjTimestamps.parse("lixo\n\n10:00 X\n0:00 Y") == [
             %{start_ms: 0, dj_name: "Y"},
             %{start_ms: 600_000, dj_name: "X"}
           ]
  end

  test "blank input -> []" do
    assert DjTimestamps.parse("") == []
    assert DjTimestamps.parse(nil) == []
  end
end
