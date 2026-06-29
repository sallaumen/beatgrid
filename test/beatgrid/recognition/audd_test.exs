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
    assert {:error, _} = Audd.parse_response(%{"status" => "error", "error" => %{"error_message" => "bad"}})
    assert {:error, _} = Audd.parse_response(%{"weird" => true})
  end
end
