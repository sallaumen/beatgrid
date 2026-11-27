defmodule Beatgrid.Sets.Planner do
  @moduledoc """
  Builds a long set from a `PlanConfig`: lays out the energy arc, then fills each
  slot by ranking library candidates against that slot's target intensity —
  chained from the previous faixa, anchored on the preset's style journey, filtered
  by the config's styles/BPM/rating, and excluding everything already used (this
  set's members, the tracks in the chosen other playlists, and — when asked — the
  artists already placed). Picks one at random among the top few, so plans vary.

  The candidate pool is fetched once per plan (every SQL filter, BPM window
  included, is plan-constant) and each slot re-ranks it in memory; the running
  exclude set is threaded the same way (no per-slot re-query). A `:replace`
  fill replaces the set once candidates exist. Each new track connects to its
  predecessor, leaving earlier transitions intact when extending a set.
  """

  alias Beatgrid.{Error, Gold}
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

  @doc "Plans or extends the set. An empty candidate pool leaves it untouched."
  @spec run(RecSet.t(), PlanConfig.t()) :: {:ok, RecSet.t()} | {:error, Error.t()}
  def run(%RecSet{} = set, %PlanConfig{} = config) do
    # Read BEFORE a :replace clears — the reference may be this very set.
    reference = reference_pool(config)
    preset = Presets.get(config.preset)
    members = if config.fill_mode == :append, do: RecSetQuery.ordered_tracks(set.id), else: []
    exclude = initial_exclusions(members, config)
    pool = fetch_pool(exclude, config, preset, reference)

    if pool == [] do
      {:error, Error.new(:no_candidates, "No tracks match the planning criteria")}
    else
      ctx = %{
        set: set,
        config: config,
        preset: preset,
        count: min(plan_count(config, preset, pool), length(pool)),
        pool: pool,
        gold_pool: Enum.filter(pool, &Gold.gold?/1)
      }

      maybe_clear(set, config.fill_mode)
      artists = MapSet.new(members, &artist_key/1)
      since_gold = members |> Enum.reverse() |> Enum.take_while(&(not Gold.gold?(&1))) |> length()
      fill_slots(ctx, {exclude, artists, List.last(members), since_gold})
      {:ok, set}
    end
  end

  defp initial_exclusions(members, config) do
    MapSet.new(Enum.map(members, & &1.id) ++ Sets.cross_set_track_ids(config.exclude_set_ids))
  end

  # One SQL fetch per plan (every hard filter is plan-constant); slots re-rank
  # it in memory.
  defp fetch_pool(exclude, config, preset, reference) do
    exclude
    |> MapSet.to_list()
    |> Mixing.candidate_pool(candidate_opts(config, preset, reference))
  end

  defp fill_slots(ctx, initial_acc) do
    _spent_acc =
      ctx.count
      |> EnergyArc.plan(ctx.config.arc_shape)
      |> Enum.with_index()
      |> Enum.reduce(initial_acc, fn {slot, index}, acc -> fill_slot(ctx, slot, index, acc) end)

    :ok
  end

  # nil = plan from the whole library; a list = restrict the pool to these track
  # ids (the reference set's members). Read once, up front.
  defp reference_pool(%PlanConfig{reference_set_id: id}) when id in [nil, ""], do: nil
  defp reference_pool(%PlanConfig{reference_set_id: id}), do: RecSetQuery.track_ids_in([id])

  defp maybe_clear(set, :replace), do: Sets.clear_quiet(set)
  defp maybe_clear(set, :append), do: set

  defp plan_count(config, preset, pool) do
    config
    |> PlanConfig.count(&estimate_from_pool(pool, &1, preset))
    |> min(preset.max_tracks)
    |> max(1)
  end

  defp estimate_from_pool(pool, minutes, preset) do
    durations = for %{duration_ms: ms} <- pool, is_integer(ms) and ms > 0, do: ms

    case durations do
      [] -> Sets.estimate_count_for_duration(minutes, preset: preset.key)
      known -> max(2, ceil(minutes * 60_000 * length(known) / Enum.sum(known)))
    end
  end

  defp fill_slot(ctx, slot, index, {exclude, artists, prev, since_gold}) do
    opts = rank_opts(ctx, slot, index, exclude, prev)

    case ranked_for(ctx, since_gold, opts) do
      [] ->
        {exclude, artists, prev, since_gold}

      ranked ->
        chosen = pick(ranked, artists, ctx.config.avoid_artist_repeat, slot.role)
        transition = prev && Sets.suggest_transition(prev, chosen.track)
        {:ok, _} = Sets.append_quiet(ctx.set, chosen.track, slot.role, transition)

        {MapSet.put(exclude, chosen.track.id), MapSet.put(artists, artist_key(chosen.track)),
         chosen.track, next_gold_gap(ctx.config, since_gold, chosen.track)}
    end
  end

  # The gold quota ("garantir 1 ouro a cada N"): when the last N-1 picks had no
  # Selo Ouro, this slot ranks gold candidates only — so no window of N goes
  # gold-less. A dry gold pool falls back to the normal ranking (never stall);
  # a naturally-picked gold resets the gap like a forced one.
  defp ranked_for(%{config: %PlanConfig{gold_every: n}} = ctx, since_gold, opts)
       when is_integer(n) and since_gold >= n - 1 do
    case Mixing.rank_pool(ctx.gold_pool, opts) do
      [] -> Mixing.rank_pool(ctx.pool, opts)
      golds -> golds
    end
  end

  defp ranked_for(ctx, _since_gold, opts), do: Mixing.rank_pool(ctx.pool, opts)

  defp next_gold_gap(%PlanConfig{gold_every: nil}, since_gold, _track), do: since_gold

  defp next_gold_gap(_config, since_gold, track) do
    if Beatgrid.Gold.gold?(track), do: 0, else: since_gold + 1
  end

  defp rank_opts(ctx, slot, index, exclude, prev) do
    [
      prev: prev,
      target_style:
        Presets.phase_target_style(ctx.preset, index, ctx.count, ctx.set.target_style),
      target_intensity: slot.target_intensity,
      exclude: MapSet.to_list(exclude),
      limit: @topk,
      weights: weights_for(ctx.config)
    ] ++ tier_opts(ctx.config)
  end

  # pool_opts/3 may also carry :style_tiers — a scoring knob candidate_pool/2
  # just ignores.
  defp candidate_opts(config, preset, reference) do
    [
      bpm_min: config.bpm_min,
      bpm_max: config.bpm_max,
      min_rating: config.min_rating,
      less_vocals: config.less_vocals
    ] ++ pool_opts(config, preset, reference)
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
