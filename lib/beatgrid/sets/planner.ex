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

  # "Priorizar bem avaliadas": rating takes the lead but the arc still breathes.
  # An influence, never a filter — the DJ's ratings are sparse, so unrated tracks
  # keep competing on the other dimensions.
  @rating_weights %{style: 15, harmony: 20, intensity: 25, bpm: 12, rating: 28}

  @doc "Plans (or extends) `set` per `config`. Returns `{:ok, set}`."
  @spec run(RecSet.t(), PlanConfig.t()) :: {:ok, RecSet.t()}
  def run(%RecSet{} = set, %PlanConfig{} = config) do
    # Read the reference pool BEFORE clearing, so referencing the very set being
    # replaced re-plans from its own (pre-clear) tracks.
    reference = reference_pool(config)
    set = maybe_clear(set, config.fill_mode)
    preset = Presets.get(config.preset)
    count = plan_count(config, preset)

    members = RecSetQuery.ordered_tracks(set.id)

    exclude0 =
      MapSet.new(Enum.map(members, & &1.id) ++ Sets.cross_set_track_ids(config.exclude_set_ids))

    # The reduce threads the running exclude/used-artists/prev/gold-gap
    # accumulator; its final value is spent (the fill is via append side
    # effects), so discard it.
    ctx = %{set: set, config: config, preset: preset, count: count, reference: reference}

    _ =
      count
      |> EnergyArc.plan(config.arc_shape)
      |> Enum.with_index()
      |> Enum.reduce({exclude0, MapSet.new(), List.last(members), 0}, fn {slot, index}, acc ->
        fill_slot(ctx, slot, index, acc)
      end)

    Sets.connect_all(set)
    {:ok, set}
  end

  # nil = plan from the whole library; a list = restrict the pool to these track
  # ids (the reference set's members). Read once, up front.
  defp reference_pool(%PlanConfig{reference_set_id: id}) when id in [nil, ""], do: nil
  defp reference_pool(%PlanConfig{reference_set_id: id}), do: RecSetQuery.track_ids_in([id])

  defp maybe_clear(set, :replace), do: Sets.clear(set)
  defp maybe_clear(set, :append), do: set

  defp plan_count(config, preset) do
    config
    |> PlanConfig.count(&Sets.estimate_count_for_duration(&1, preset: preset.key))
    |> min(preset.max_tracks)
    |> max(1)
  end

  defp fill_slot(ctx, slot, index, {exclude, artists, prev, since_gold}) do
    opts = rank_opts(ctx, slot, index, exclude, prev)

    case ranked_for(ctx.config, since_gold, opts) do
      [] ->
        {exclude, artists, prev, since_gold}

      ranked ->
        chosen = pick(ranked, artists, ctx.config.avoid_artist_repeat, slot.role)
        {:ok, _} = Sets.append_quiet(ctx.set, chosen.track, slot.role)

        {MapSet.put(exclude, chosen.track.id), MapSet.put(artists, artist_key(chosen.track)),
         chosen.track, next_gold_gap(ctx.config, since_gold, chosen.track)}
    end
  end

  # The gold quota ("garantir 1 ouro a cada N"): when the last N-1 picks had no
  # Selo Ouro, this slot ranks gold candidates only — so no window of N goes
  # gold-less. A dry gold pool falls back to the normal ranking (never stall);
  # a naturally-picked gold resets the gap like a forced one.
  defp ranked_for(%PlanConfig{gold_every: n}, since_gold, opts)
       when is_integer(n) and since_gold >= n - 1 do
    case Mixing.rank([{:gold_only, true} | opts]) do
      [] -> Mixing.rank(opts)
      golds -> golds
    end
  end

  defp ranked_for(_config, _since_gold, opts), do: Mixing.rank(opts)

  defp next_gold_gap(%PlanConfig{gold_every: nil}, since_gold, _track), do: since_gold

  defp next_gold_gap(_config, since_gold, track) do
    if Beatgrid.Gold.gold?(track), do: 0, else: since_gold + 1
  end

  defp rank_opts(ctx, slot, index, exclude, prev) do
    %{config: config, preset: preset} = ctx

    [
      prev: prev,
      target_style: Presets.phase_target_style(preset, index, ctx.count, ctx.set.target_style),
      target_intensity: slot.target_intensity,
      exclude: MapSet.to_list(exclude),
      limit: @topk,
      weights: weights_for(config),
      bpm_min: config.bpm_min,
      bpm_max: config.bpm_max,
      min_rating: config.min_rating,
      less_vocals: config.less_vocals
    ] ++ pool_opts(config, preset, ctx.reference)
  end

  # Library mode: the whole library, gated by the style whitelist/exclusions.
  defp pool_opts(config, preset, nil) do
    [exclude_styles: Enum.uniq(preset.exclude_styles ++ config.exclude_styles)] ++
      style_opts(config)
  end

  # Reference mode: the pool IS the reference set, PLUS any marked style pulled
  # from the full library (the "escape"). The style whitelist/exclusions don't
  # filter the curated reference; tier WEIGHTS still score the escaped tracks.
  defp pool_opts(config, _preset, reference_ids) do
    escape = Enum.uniq(config.allow_styles ++ config.secondary_styles)
    [restrict_ids: reference_ids, escape_styles: escape] ++ tier_opts(config)
  end

  # The style scale: primaries score full, "se muito boa" folders join the pool
  # at a reduced style weight — they only crack the top-K when rating/gold/arc
  # fit make them stand out. Nothing marked = every style, plain affinity.
  @secondary_tier 0.4

  defp style_opts(config) do
    case tiers_map(config) do
      tiers when map_size(tiers) == 0 -> []
      tiers -> [allow_styles: Map.keys(tiers), style_tiers: tiers]
    end
  end

  defp tier_opts(config) do
    case tiers_map(config) do
      tiers when map_size(tiers) == 0 -> []
      tiers -> [style_tiers: tiers]
    end
  end

  defp tiers_map(config) do
    config.secondary_styles
    |> Map.new(&{&1, @secondary_tier})
    |> Map.merge(Map.new(config.allow_styles, &{&1, 1.0}))
  end

  # Harmony chains each pick to the PREVIOUS track's key, and over a long plan
  # that locks the whole playlist into one key neighborhood ("playlist só de
  # 9A") — so planning zeroes it unless the DJ opts back in with match_keys.
  # The live console keeps its harmony weight: there it scores one next track,
  # not a 96-long chain.
  defp weights_for(config) do
    base = if config.prioritize_rating, do: @rating_weights, else: @weights
    if config.match_keys, do: base, else: %{base | harmony: 0}
  end

  # Top-K random pick behind a preference ladder that never stalls: honor the
  # artist spread first, then steer Selo Ouro toward the highlights — a pico
  # slot takes a gold when one is in reach, any other slot saves the golds for
  # the peaks (the same "distribute the good stuff" philosophy remix applies to
  # manual sets). Each preference falls back to the full pool when it can't be
  # satisfied, so shaping never beats filling.
  defp pick(ranked, artists, avoid_artist?, role) do
    ranked
    |> prefer(avoid_artist?, &(not MapSet.member?(artists, artist_key(&1.track))))
    |> prefer(true, gold_preference(role))
    |> Enum.random()
  end

  defp prefer(pool, false, _keep?), do: pool

  defp prefer(pool, true, keep?) do
    case Enum.filter(pool, keep?) do
      [] -> pool
      kept -> kept
    end
  end

  defp gold_preference("pico"), do: &gold?(&1.track)
  defp gold_preference(_role), do: &(not gold?(&1.track))

  defp gold?(track), do: Beatgrid.Gold.gold?(track)

  defp artist_key(track), do: track.norm_artist || track.tag_artist
end
