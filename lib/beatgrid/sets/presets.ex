defmodule Beatgrid.Sets.Presets do
  @moduledoc """
  The long-set planning presets. A preset is a *starting point* for the Planning
  Studio: it names a style **journey** (per-phase target styles across the set)
  and a `max_tracks` ceiling, and `to_config_fields/1` maps it to the studio
  control values the UI pre-fills (allowed styles, excluded styles, arc shape).
  The user then adjusts freely; `"custom"` starts from a blank journey that
  inherits the set's own target style.

  Pure data + lookup. No DB, no side effects.
  """

  @max_tracks 240

  @presets [
    %{
      key: "forro_roots_marathon",
      name: "Forro Roots Marathon",
      target_style: "forro_roots",
      max_tracks: @max_tracks,
      exclude_styles: ["mpb", "forro_mpb"],
      description: "A long roots-first set with only close Forro material around it.",
      phases: [%{until: 1.0, target_style: "forro_roots"}]
    },
    %{
      key: "roots_to_forro_mpb",
      name: "Roots to Forro MPB",
      target_style: "forro_roots",
      max_tracks: @max_tracks,
      exclude_styles: ["mpb"],
      description: "Starts in Forro Roots, passes through Forro, and lands in Forro MPB.",
      phases: [
        %{until: 0.35, target_style: "forro_roots"},
        %{until: 0.65, target_style: "forro"},
        %{until: 1.0, target_style: "forro_mpb"}
      ]
    },
    %{
      key: "roots_to_classic",
      name: "Roots to Classic Forro",
      target_style: "forro_roots",
      max_tracks: @max_tracks,
      exclude_styles: ["mpb", "forro_mpb", "forro_psicodelico"],
      description: "A roots opening that resolves into classic Forro.",
      phases: [
        %{until: 0.45, target_style: "forro_roots"},
        %{until: 0.75, target_style: "forro"},
        %{until: 1.0, target_style: "forro_classico"}
      ]
    },
    %{
      key: "forro_orbit",
      name: "Forro Orbit",
      target_style: "forro_roots",
      max_tracks: @max_tracks,
      exclude_styles: ["mpb"],
      description: "Mostly Forro, with controlled touches from nearby Forro folders.",
      phases: [
        %{until: 0.25, target_style: "forro_roots"},
        %{until: 0.45, target_style: "forro_classico"},
        %{until: 0.70, target_style: "forro"},
        %{until: 0.85, target_style: "forro_in_the_light"},
        %{until: 1.0, target_style: "forro_roots"}
      ]
    },
    %{
      key: "mpb_set",
      name: "MPB Set",
      target_style: "mpb",
      max_tracks: @max_tracks,
      exclude_styles: ["forro_psicodelico"],
      description: "A dedicated MPB set, used only when explicitly selected.",
      phases: [%{until: 1.0, target_style: "mpb"}]
    },
    %{
      key: "custom",
      name: "Custom",
      target_style: nil,
      max_tracks: @max_tracks,
      exclude_styles: [],
      description: "Blank journey: your chosen styles, BPM, arc and rating drive it.",
      phases: [%{until: 1.0, target_style: nil}]
    }
  ]

  @doc "All presets, in UI order."
  @spec all() :: [map()]
  def all, do: @presets

  @doc "The preset for `key`, falling back to `\"custom\"` for anything unknown."
  @spec get(String.t() | nil) :: map()
  def get(key),
    do: Enum.find(@presets, &(&1.key == key)) || Enum.find(@presets, &(&1.key == "custom"))

  @doc "The hard track ceiling any single plan accepts."
  @spec max_tracks() :: pos_integer()
  def max_tracks, do: @max_tracks

  @doc """
  The control values the Planning Studio pre-fills when this preset is picked:
  the allowed-styles whitelist (the distinct styles its journey visits — empty
  for custom), the excluded styles, and the arc shape (`:wave` for now).
  """
  @spec to_config_fields(String.t() | map()) :: %{
          allow_styles: [String.t()],
          exclude_styles: [String.t()],
          arc_shape: atom()
        }
  def to_config_fields(key) when is_binary(key), do: to_config_fields(get(key))

  def to_config_fields(%{} = preset) do
    %{
      allow_styles: journey_styles(preset),
      exclude_styles: preset.exclude_styles,
      arc_shape: :wave
    }
  end

  @doc """
  The target style for the slot at `index` of `count`, following the preset's
  journey; `nil`-phase styles (custom) inherit `set_target_style`.
  """
  @spec phase_target_style(map(), non_neg_integer(), pos_integer(), String.t() | nil) ::
          String.t() | nil
  def phase_target_style(%{phases: phases}, index, count, set_target_style) do
    progress = if count <= 1, do: 1.0, else: index / (count - 1)
    phase = Enum.find(phases, &(progress <= &1.until)) || List.last(phases)
    phase.target_style || set_target_style
  end

  defp journey_styles(%{phases: phases}) do
    phases |> Enum.map(& &1.target_style) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end
end
