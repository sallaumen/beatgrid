defmodule Beatgrid.Sets.Remixer do
  @moduledoc """
  Pure arc reassignment for a remix: given the set's cards (`%{track, intensity,
  gold}`), lays the energy arc over the same tracks and hands each slot the
  best-fitting remaining card. No DB, no side effects — `Beatgrid.Sets.remix/1`
  owns persistence and broadcasting.
  """

  alias Beatgrid.Sets.EnergyArc

  @jitter 0.08

  @type card :: %{track: struct() | map(), intensity: float(), gold: boolean()}

  @doc "Orders the cards along the arc. Returns `[{track, role}]` in position order."
  @spec order([card()]) :: [{struct() | map(), String.t()}]
  def order([]), do: []

  def order(cards) do
    cards
    |> length()
    |> EnergyArc.plan()
    |> assign_arc(cards)
  end

  # Assigns a track to each arc slot, but visits the CENTER slots first so the best /
  # gold / highest-energy tracks get claimed for the middle of the set (the peak the
  # crowd actually hears) instead of being grabbed by the early slots; edge slots take
  # what's left. Reassembled in position order. Top-K sampling keeps each remix varied.
  defp assign_arc(plan, cards) do
    n = length(plan)

    {assigned, _} =
      plan
      |> Enum.with_index()
      |> Enum.sort_by(fn {_slot, i} -> -centrality(i, n) end)
      |> Enum.reduce({%{}, cards}, fn {slot, i}, {acc, remaining} ->
        chosen = pick_card(slot, centrality(i, n), remaining)
        {Map.put(acc, i, {chosen.track, slot.role}), List.delete(remaining, chosen)}
      end)

    Enum.map(0..(n - 1)//1, &Map.fetch!(assigned, &1))
  end

  # 1.0 at the center of the set, tapering to 0.0 at the very ends.
  defp centrality(_i, n) when n <= 1, do: 1.0
  defp centrality(i, n), do: 1.0 - abs(i - (n - 1) / 2) / ((n - 1) / 2)

  # Random among the tracks whose fit is within a small margin of the best: when one
  # track clearly fits best (a standout/gold for a center peak) it's placed decisively;
  # when several fit similarly, it samples among them so each remix varies.
  defp pick_card(slot, c, cards) do
    scored = Enum.map(cards, &{&1, slot_fit(slot, c, &1)})
    best = scored |> Enum.map(&elem(&1, 1)) |> Enum.max()

    scored
    |> Enum.filter(fn {_card, s} -> s >= best - @jitter end)
    |> Enum.random()
    |> elem(0)
  end

  # Center slots aim for the full target intensity; edge slots aim lower — so the
  # high-energy tracks fit the middle. Gold gets a centrality-scaled nudge, pulling
  # the rare gems toward the peak instead of the warm-up.
  defp slot_fit(%{target_intensity: ti, role: role}, c, %{intensity: i, gold: gold}) do
    target = ti * (0.68 + 0.32 * c)
    fit = 1.0 - abs(target - i)
    if role == "pico" and gold, do: fit + 0.35 * c, else: fit
  end
end
