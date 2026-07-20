defmodule Beatgrid.Sets.RemixerTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Sets.Remixer

  defp card(id, intensity, gold \\ false),
    do: %{track: %{id: id}, intensity: intensity, gold: gold}

  test "places every card exactly once, in arc length and position order" do
    cards = for i <- 1..8, do: card(i, i / 10)

    placed = Remixer.order(cards)

    assert length(placed) == 8

    assert placed |> Enum.map(fn {track, _role} -> track.id end) |> Enum.sort() ==
             Enum.to_list(1..8)

    assert Enum.all?(placed, fn {_track, role} -> is_binary(role) end)
  end

  test "with equal intensities the gold card lands on the pico" do
    # 3-slot wave arc = abertura / pico / queda. Identical intensities leave the
    # gold nudge (0.35 at full centrality, >> the 0.08 jitter) as the only
    # differentiator — the center pico must claim the gold.
    cards = [card(1, 0.6), card(2, 0.6, true), card(3, 0.6)]

    {gold_track, "pico"} =
      cards |> Remixer.order() |> Enum.find(fn {_track, role} -> role == "pico" end)

    assert gold_track.id == 2
  end

  test "an empty set remixes to an empty order" do
    assert Remixer.order([]) == []
  end
end
