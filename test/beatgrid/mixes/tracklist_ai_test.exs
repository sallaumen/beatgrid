defmodule Beatgrid.Mixes.TracklistAITest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  alias Beatgrid.Mixes.TracklistAI

  test "returns [] for a blank description without calling the AI" do
    assert TracklistAI.parse("") == []
    assert TracklistAI.parse(nil) == []
  end

  test "parses the AI's structured tracklist into ordered maps" do
    expect(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "tracklist" => [
           %{"position" => 0, "start_seconds" => 0, "artist" => "A", "title" => "One"},
           %{"position" => 1, "start_seconds" => 270, "artist" => "B", "title" => "Two"}
         ]
       }}
    end)

    assert [%{position: 0, start_seconds: 0, artist: "A", title: "One"}, t2] =
             TracklistAI.parse("00:00 A - One\n04:30 B - Two")

    assert t2.start_seconds == 270 and t2.artist == "B"
  end

  test "returns [] when the AI finds no tracklist" do
    expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"tracklist" => []}} end)
    assert TracklistAI.parse("just some hype text, no tracklist") == []
  end
end
