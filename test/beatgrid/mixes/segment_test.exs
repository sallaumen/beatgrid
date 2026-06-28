defmodule Beatgrid.Mixes.SegmentTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Mixes.Segment

  test "requires position and start_ms" do
    cs = Segment.changeset(%Segment{}, %{})
    refute cs.valid?
    assert %{position: ["can't be blank"], start_ms: ["can't be blank"]} = errors_on(cs)
  end

  test "valid with position and start_ms" do
    assert Segment.changeset(%Segment{}, %{position: 0, start_ms: 0}).valid?
  end
end
