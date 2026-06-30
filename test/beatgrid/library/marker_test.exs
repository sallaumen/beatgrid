defmodule Beatgrid.Library.MarkerTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Library.Marker

  test "type/source default for legacy markers; color by type" do
    assert Marker.type(%{"ms" => 0}) == "cue"
    assert Marker.source(%{"ms" => 0}) == "manual"
    assert Marker.type(%{"type" => "intro"}) == "intro"
    assert Marker.type(%{"type" => "bogus"}) == "cue"
    assert Marker.source(%{"source" => "auto"}) == "auto"
    assert Marker.auto?(%{"source" => "auto"})
    refute Marker.auto?(%{"ms" => 0})
    assert Marker.color(%{"type" => "intro"}) == "#5ad1a0"
    assert Marker.color(%{"type" => "outro"}) == "#ff5d6c"
    assert Marker.color(%{"ms" => 0}) == "#ffb020"
  end

  test "normalize_type/source coerce unknowns" do
    assert Marker.normalize_type("outro") == "outro"
    assert Marker.normalize_type("x") == "cue"
    assert Marker.normalize_source("auto") == "auto"
    assert Marker.normalize_source("x") == "manual"
  end

  test "intro = earliest intro marker, outro = latest outro marker, nil when none" do
    track = %{
      cue_points: [
        %{"ms" => 90_000, "type" => "outro"},
        %{"ms" => 5_000, "type" => "intro"},
        %{"ms" => 120_000, "type" => "outro"},
        %{"ms" => 30_000, "type" => "cue"}
      ]
    }

    assert Marker.intro(track)["ms"] == 5_000
    assert Marker.outro(track)["ms"] == 120_000
    assert Marker.intro(%{cue_points: []}) == nil
    assert Marker.outro(%{cue_points: nil}) == nil
  end
end
