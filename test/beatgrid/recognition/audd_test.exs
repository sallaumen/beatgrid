defmodule Beatgrid.Recognition.AuddTest do
  use ExUnit.Case, async: true
  alias Beatgrid.Recognition.Audd

  test "parse_response: success with a result" do
    body = %{"status" => "success", "result" => %{"artist" => "Falamansa", "title" => "Xote"}}
    assert Audd.parse_response(body) == {:ok, %{artist: "Falamansa", title: "Xote"}}
  end

  test "parse_response: null result -> no_match" do
    assert Audd.parse_response(%{"status" => "success", "result" => nil}) == {:ok, :no_match}
  end

  test "parse_response: error / unexpected -> error" do
    assert {:error, _} =
             Audd.parse_response(%{"status" => "error", "error" => %{"error_message" => "bad"}})

    assert {:error, _} = Audd.parse_response(%{"weird" => true})
  end

  describe "snippet_window/2" do
    test "centers a ~20s window on the middle of the segment" do
      # 4-min segment 0..240_000, middle 120_000 -> [110_000, 130_000]
      assert {110_000, 20_000} = Audd.snippet_window(0, 240_000)
    end

    test "respects a non-zero segment start" do
      # 100_000..160_000 (1 min), middle 130_000 -> [120_000, 140_000]
      assert {120_000, 20_000} = Audd.snippet_window(100_000, 160_000)
    end

    test "for a short segment, uses the whole segment instead of overrunning the start" do
      assert {0, 8_000} = Audd.snippet_window(0, 8_000)
    end

    test "the window never starts before the segment" do
      {offset, dur} = Audd.snippet_window(50_000, 62_000)
      assert offset >= 50_000
      assert offset + dur <= 62_000
    end
  end
end
