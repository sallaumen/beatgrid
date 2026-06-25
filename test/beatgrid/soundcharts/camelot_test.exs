defmodule Beatgrid.Soundcharts.CamelotTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Soundcharts.Camelot

  describe "from_key/2 (pitch-class key + mode → Camelot wheel code)" do
    test "major keys map to the B side" do
      assert Camelot.from_key(0, 1) == "8B"
      assert Camelot.from_key(7, 1) == "9B"
      assert Camelot.from_key(8, 1) == "4B"
      assert Camelot.from_key(11, 1) == "1B"
    end

    test "minor keys map to the A side" do
      assert Camelot.from_key(9, 0) == "8A"
      assert Camelot.from_key(0, 0) == "5A"
      # B minor (the Disritmia probe: key 11, mode 0)
      assert Camelot.from_key(11, 0) == "10A"
    end

    test "returns nil for unknown key/mode" do
      assert Camelot.from_key(-1, 1) == nil
      assert Camelot.from_key(nil, 0) == nil
      assert Camelot.from_key(5, nil) == nil
      assert Camelot.from_key(12, 1) == nil
    end
  end
end
