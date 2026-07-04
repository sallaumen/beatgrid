defmodule Beatgrid.Sets.EnergyArc do
  @moduledoc """
  The energy-arc planner for a full set: given a track `count` and an arc `shape`,
  returns one slot per faixa — `%{role, target_intensity}` — that the planner fills
  by ranking candidates against each slot's `target_intensity`.

  `role` stays in the set vocabulary (`abertura`/`pico`/`respiro`/`queda`) so the
  arc chart and remix keep working; `target_intensity` (0–1) is the energy the slot
  aims for. Five shapes:

    * `:wave`   — an opener, repeated peak↔respiro waves, and a fade-out (the
      classic block model; block sizes are randomized, so it varies per call).
    * `:rise`   — energy climbs monotonically and crests at the end.
    * `:fall`   — an early crest, then a long descent to a calm close.
    * `:peak`   — a symmetric mountain: rises to a mid-set crest, descends.
    * `:steady` — a plateau at a mid-high intensity, easing in and out.

  Pure: no DB, no side effects. Lives in `Sets` (planning domain), not `Mixing`
  (the scorer), so the scorer never depends back on planning.
  """

  # Discrete intensities for the wave model's roles (the peak↔respiro vocabulary).
  @arc_intensity %{"abertura" => 0.70, "pico" => 0.95, "respiro" => 0.55, "queda" => 0.42}
  @shapes ~w(wave rise fall peak steady)a

  @type slot :: %{role: String.t(), target_intensity: float()}

  @doc "The supported arc shapes."
  @spec shapes() :: [atom()]
  def shapes, do: @shapes

  @doc """
  Builds an energy-arc plan of exactly `count` slots for `shape` (default `:wave`).
  Non-positive counts return `[]`; 1 and 2 degrade to `abertura` / `abertura+queda`
  for every shape.
  """
  @spec plan(integer(), atom()) :: [slot()]
  def plan(count, shape \\ :wave)

  def plan(count, _shape) when not is_integer(count) or count <= 0, do: []
  def plan(1, _shape), do: [slot("abertura")]
  def plan(2, _shape), do: [slot("abertura"), slot("queda")]
  def plan(count, :wave), do: wave(count)
  def plan(count, shape) when shape in @shapes, do: curve(count, shape)
  def plan(count, _unknown), do: wave(count)

  # ── :wave — the block model (moved verbatim from Mixing.block_plan) ──────────

  defp wave(count) do
    {head_n, tail_n} = if count >= 16, do: {2, 2}, else: {1, 1}
    mid_n = count - head_n - tail_n

    List.duplicate(slot("abertura"), head_n) ++
      middle_waves(mid_n, :pico, []) ++
      List.duplicate(slot("queda"), tail_n)
  end

  defp middle_waves(0, _next, acc), do: acc

  # A peak with room left for a respiro (3) + a closing peak (3) keeps waving;
  # otherwise this is the closing peak and it absorbs whatever remains.
  defp middle_waves(n, :pico, acc) when n >= 10 do
    p = Enum.random(4..5)
    middle_waves(n - p, :respiro, acc ++ arc_run("pico", p))
  end

  defp middle_waves(n, :pico, acc), do: acc ++ arc_run("pico", n)

  defp middle_waves(n, :respiro, acc) do
    v = n |> Kernel.-(3) |> min(Enum.random(3..4)) |> max(3)
    middle_waves(n - v, :pico, acc ++ arc_run("respiro", v))
  end

  defp arc_run(role, size), do: List.duplicate(slot(role), size)

  # ── :rise / :fall / :peak / :steady — continuous intensity curves ────────────

  defp curve(count, shape) do
    last = count - 1

    for i <- 0..last do
      ti = intensity_at(shape, i / last)
      %{role: role_for_intensity(ti), target_intensity: Float.round(ti, 3)}
    end
  end

  defp intensity_at(:rise, p), do: lerp(0.55, 0.98, p)

  defp intensity_at(:fall, p) when p <= 0.2, do: lerp(0.60, 0.95, p / 0.2)
  defp intensity_at(:fall, p), do: lerp(0.95, 0.35, (p - 0.2) / 0.8)

  defp intensity_at(:peak, p), do: 0.5 + 0.45 * :math.sin(:math.pi() * p)

  defp intensity_at(:steady, p) when p <= 0.08, do: lerp(0.64, 0.80, p / 0.08)
  defp intensity_at(:steady, p) when p >= 0.92, do: lerp(0.80, 0.64, (p - 0.92) / 0.08)
  defp intensity_at(:steady, _p), do: 0.80

  defp lerp(a, b, p), do: a + (b - a) * p

  # Continuous intensity → the nearest arc role, so the chart/remix stay coherent.
  defp role_for_intensity(ti) when ti >= 0.80, do: "pico"
  defp role_for_intensity(ti) when ti >= 0.62, do: "abertura"
  defp role_for_intensity(ti) when ti >= 0.50, do: "respiro"
  defp role_for_intensity(_ti), do: "queda"

  defp slot(role), do: %{role: role, target_intensity: Map.fetch!(@arc_intensity, role)}
end
