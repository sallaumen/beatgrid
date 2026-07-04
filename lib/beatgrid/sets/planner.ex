defmodule Beatgrid.Sets.Planner do
  @moduledoc """
  Builds a long set from a `PlanConfig`: lays out the energy arc, then fills each
  slot by ranking library candidates against that slot's target intensity —
  chained from the previous faixa, anchored on the preset's style journey, filtered
  by the config's styles/BPM/rating, and excluding everything already used (this
  set's members, the tracks in the chosen other playlists, and — when asked — the
  artists already placed). Picks one at random among the top few, so plans vary.

  The running exclude set is threaded in memory (no per-slot member re-query), and
  a `:replace` fill clears the set first. Finishes by connecting every consecutive
  pair with a transition.
  """

  alias Beatgrid.Mixing
  alias Beatgrid.Sets
  alias Beatgrid.Sets.{EnergyArc, PlanConfig, Presets, RecSet, RecSetQuery}

  @topk 5

  # Planning weights differ from the live console's: the energy arc (intensity) and
  # tempo continuity (bpm) lead, so respiros actually calm down and the tempo
  # doesn't jump — the user's "arco digno de DJ, reduzindo o tempo aos poucos".
  @weights %{style: 20, harmony: 25, intensity: 35, bpm: 18, rating: 2}

  @doc "Plans (or extends) `set` per `config`. Returns `{:ok, set}`."
  @spec run(RecSet.t(), PlanConfig.t()) :: {:ok, RecSet.t()}
  def run(%RecSet{} = set, %PlanConfig{} = config) do
    set = maybe_clear(set, config.fill_mode)
    preset = Presets.get(config.preset)
    count = plan_count(config, preset)

    members = RecSetQuery.ordered_tracks(set.id)

    exclude0 =
      MapSet.new(Enum.map(members, & &1.id) ++ Sets.cross_set_track_ids(config.exclude_set_ids))

    # The reduce threads the running exclude/used-artists/prev accumulator; its
    # final value is spent (the fill is via append side effects), so discard it.
    _ =
      count
      |> EnergyArc.plan(config.arc_shape)
      |> Enum.with_index()
      |> Enum.reduce({exclude0, MapSet.new(), List.last(members)}, fn {slot, index}, acc ->
        fill_slot(set, config, preset, count, slot, index, acc)
      end)

    Sets.connect_all(set)
    {:ok, set}
  end

  defp maybe_clear(set, :replace), do: Sets.clear(set)
  defp maybe_clear(set, :append), do: set

  defp plan_count(config, preset) do
    config
    |> PlanConfig.count(&Sets.estimate_count_for_duration(&1, preset: preset.key))
    |> min(preset.max_tracks)
    |> max(1)
  end

  defp fill_slot(set, config, preset, count, slot, index, {exclude, artists, prev}) do
    opts = rank_opts(set, config, preset, count, slot, index, exclude, prev)

    case Mixing.rank(opts) do
      [] ->
        {exclude, artists, prev}

      ranked ->
        chosen = pick(ranked, artists, config.avoid_artist_repeat)
        {:ok, _} = Sets.append(set, chosen.track, slot.role)

        {MapSet.put(exclude, chosen.track.id), MapSet.put(artists, artist_key(chosen.track)),
         chosen.track}
    end
  end

  defp rank_opts(set, config, preset, count, slot, index, exclude, prev) do
    [
      prev: prev,
      target_style: Presets.phase_target_style(preset, index, count, set.target_style),
      target_intensity: slot.target_intensity,
      exclude: MapSet.to_list(exclude),
      limit: @topk,
      weights: @weights,
      allow_styles: config.allow_styles,
      exclude_styles: Enum.uniq(preset.exclude_styles ++ config.exclude_styles),
      bpm_min: config.bpm_min,
      bpm_max: config.bpm_max,
      min_rating: config.min_rating,
      gold_only: config.gold_only,
      less_vocals: config.less_vocals
    ]
  end

  # Top-K random pick. When avoiding repeats, prefer candidates whose artist
  # hasn't been placed yet, but never stall — fall back to the full top-K.
  defp pick(ranked, _artists, false), do: Enum.random(ranked)

  defp pick(ranked, artists, true) do
    case Enum.reject(ranked, &MapSet.member?(artists, artist_key(&1.track))) do
      [] -> Enum.random(ranked)
      fresh -> Enum.random(fresh)
    end
  end

  defp artist_key(track), do: track.norm_artist || track.tag_artist
end
