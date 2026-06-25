defmodule Beatgrid.Soundcharts.CamelotNeighborsTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Soundcharts.Camelot

  describe "neighbors/1 (harmonically compatible codes)" do
    test "includes self, ±1 same letter, and the relative major/minor" do
      assert Enum.sort(Camelot.neighbors("8A")) == Enum.sort(["8A", "7A", "9A", "8B"])
      assert Enum.sort(Camelot.neighbors("8B")) == Enum.sort(["8B", "7B", "9B", "8A"])
    end

    test "wraps around the wheel at the edges" do
      assert "12A" in Camelot.neighbors("1A")
      assert "2A" in Camelot.neighbors("1A")
      assert "1A" in Camelot.neighbors("12A")
      assert "11A" in Camelot.neighbors("12A")
    end

    test "returns [] for invalid codes" do
      assert Camelot.neighbors(nil) == []
      assert Camelot.neighbors("13A") == []
      assert Camelot.neighbors("8C") == []
      assert Camelot.neighbors("xx") == []
    end
  end

  describe "compatible?/2" do
    test "true for self, neighbor, and relative" do
      assert Camelot.compatible?("8A", "8A")
      assert Camelot.compatible?("8A", "9A")
      assert Camelot.compatible?("8A", "8B")
      assert Camelot.compatible?("12A", "1A")
    end

    test "false for distant or invalid codes" do
      refute Camelot.compatible?("8A", "3A")
      refute Camelot.compatible?("8A", "9B")
      refute Camelot.compatible?("8A", nil)
      refute Camelot.compatible?(nil, "8A")
    end
  end
end
