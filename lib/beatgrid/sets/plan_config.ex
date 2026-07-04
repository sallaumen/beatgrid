defmodule Beatgrid.Sets.PlanConfig do
  @moduledoc """
  The Planning Studio's request, as a validated, typed struct. It is the single
  place that knows the studio's knobs, their defaults and their safe ranges; the
  LiveView hands raw form params to `from_params/1` and gets back a config the
  `Planner` can trust. Not persisted — a plan is configured fresh each time.

  Fields:
    * `preset` — the starting-point preset key (drives the style journey).
    * `mode` — `:tracks` or `:duration` (how the length is bounded).
    * `track_count` / `duration_minutes` — the length, per mode.
    * `allow_styles` — genre-folder whitelist (empty = all).
    * `exclude_styles` — genre folders to hard-exclude.
    * `bpm_min` / `bpm_max` — effective-BPM window (nil = open).
    * `min_rating` — 0–10 floor (nil = any).
    * `gold_only` — only Selo Ouro tracks (manual/status/views — `Beatgrid.Gold`).
    * `less_vocals` — only instrumental-leaning tracks ("mais musicais").
    * `arc_shape` — `EnergyArc` shape.
    * `avoid_artist_repeat` — spread artists across the set when possible.
    * `exclude_set_ids` — other sets whose tracks must not repeat here.
    * `fill_mode` — `:replace` (clear first) or `:append`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Sets.{EnergyArc, Presets}

  @max_tracks Presets.max_tracks()

  @primary_key false
  embedded_schema do
    field :preset, :string, default: "custom"
    field :mode, Ecto.Enum, values: [:tracks, :duration], default: :duration
    field :track_count, :integer, default: 16
    field :duration_minutes, :integer, default: 300
    field :allow_styles, {:array, :string}, default: []
    field :exclude_styles, {:array, :string}, default: []
    field :bpm_min, :float
    field :bpm_max, :float
    field :min_rating, :integer
    field :gold_only, :boolean, default: false
    field :less_vocals, :boolean, default: false
    field :arc_shape, Ecto.Enum, values: EnergyArc.shapes(), default: :wave
    field :avoid_artist_repeat, :boolean, default: false
    field :exclude_set_ids, {:array, :string}, default: []
    field :fill_mode, Ecto.Enum, values: [:replace, :append], default: :replace
  end

  @castable ~w(preset mode track_count duration_minutes allow_styles exclude_styles
               bpm_min bpm_max min_rating gold_only less_vocals arc_shape
               avoid_artist_repeat exclude_set_ids fill_mode)a

  @doc """
  Builds a `%PlanConfig{}` from raw form params. Always returns a valid struct:
  unknown enum values and junk fall back to the field defaults, and the numeric
  fields are clamped to safe ranges — the studio should never fail to plan over a
  malformed field.
  """
  @spec from_params(map()) :: t()
  def from_params(params) when is_map(params) do
    %__MODULE__{}
    |> cast(params, @castable)
    |> clamp(:track_count, 2, @max_tracks)
    |> clamp(:duration_minutes, 15, 720)
    |> clamp(:min_rating, 0, 10)
    |> nonneg(:bpm_min)
    |> nonneg(:bpm_max)
    |> apply_changes()
  end

  @doc """
  How many tracks to plan: `track_count` in `:tracks` mode, or the `estimator`
  applied to `duration_minutes` in `:duration` mode (the estimator hits the DB
  for the average track length, so it's injected to keep this pure).
  """
  @spec count(t(), (pos_integer() -> pos_integer())) :: pos_integer()
  def count(%__MODULE__{mode: :tracks, track_count: n}, _estimator), do: n
  def count(%__MODULE__{mode: :duration, duration_minutes: m}, estimator), do: estimator.(m)

  @type t :: %__MODULE__{}

  defp clamp(changeset, field, lo, hi) do
    case get_change(changeset, field) do
      nil -> changeset
      v -> put_change(changeset, field, v |> max(lo) |> min(hi))
    end
  end

  defp nonneg(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset
      v when v < 0 -> put_change(changeset, field, 0.0)
      _ -> changeset
    end
  end
end
