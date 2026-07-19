defmodule Beatgrid.Sets do
  @moduledoc """
  Scored set-builder. A `RecSet` is a named, ordered chain of tracks the user
  assembles for a gig, anchored on a `target_style`. Tracks are appended from the
  scored candidates (`Mixing.rank`, excluding members), section by section
  (`fill_section/3`) or greedily (`auto_fill/2`). A finished set exports to an
  `.m3u` playlist under `<library_root>/_Sets` that Serato/VLC read directly.
  """
  # `where` only — reads live in the query modules; the import serves the
  # membership delete mutation below.
  import Ecto.Query, only: [where: 3]

  alias Beatgrid.Library
  alias Beatgrid.Library.{Marker, TrackQuery}
  alias Beatgrid.Mixing
  alias Beatgrid.Repo

  alias Beatgrid.Sets.{
    EnergyArc,
    PlanConfig,
    Planner,
    Presets,
    RecSet,
    RecSetQuery,
    SetTrack,
    TransitionChooser
  }

  @transition_types ~w(cut fade crossfade echo filter bass_swap brake lowpass scratch_cut spinback)

  # Console hint clamps (never-again #4: from_ms is never trusted blindly).
  @default_outro_window_ms 8_000
  @min_tail_ms 3_000

  @unsafe ~r/[\/\\:*?"<>|]/u

  @doc "The transition-type vocabulary, in UI order — screens mirror the engine."
  @spec transition_types() :: [String.t()]
  def transition_types, do: @transition_types

  @doc "Subscribe to one set's structural changes (membership/order/transitions)."
  @spec subscribe_set(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_set(set_id), do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, "sets:#{set_id}")

  # Every mutation of a set's structure notifies live listeners (the Discotecagem
  # console re-pulls its next-track hint), keeping lookahead revocable.
  defp broadcast_set_changed(set_id),
    do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, "sets:#{set_id}", {:set_changed, set_id})

  @spec list() :: [RecSet.t()]
  defdelegate list, to: RecSetQuery

  @spec get(Ecto.UUID.t()) :: RecSet.t() | nil
  defdelegate get(id), to: RecSetQuery

  @spec tracks(RecSet.t()) :: [Library.Track.t()]
  def tracks(%RecSet{id: id}), do: RecSetQuery.ordered_tracks(id)

  @doc "The set's entries (track + section role) in order — what the screen renders."
  @spec entries(RecSet.t()) :: [
          %{
            track: Library.Track.t(),
            role: String.t() | nil,
            position: integer(),
            transition: map() | nil
          }
        ]
  def entries(%RecSet{id: id}), do: RecSetQuery.ordered_entries(id)

  @doc """
  Energy + BPM series for the set's arc chart: one point per entry, in order, each
  `%{role, energy, bpm}` — `energy` (0–1) from `Mixing.intensity/1`, `bpm` the
  effective BPM (or nil). Feeds the `/set/:id` visualization (auto or manual sets).
  """
  @spec arc_series(RecSet.t()) :: [
          %{role: String.t() | nil, energy: float(), bpm: float() | nil}
        ]
  def arc_series(%RecSet{} = set) do
    set
    |> entries()
    |> Enum.map(fn e ->
      %{role: e.role, energy: Mixing.intensity(e.track), bpm: Library.effective(e.track).bpm}
    end)
  end

  @doc "The set's opening track (position order), or nil if empty — for \"Tocar set\"."
  @spec first_track(RecSet.t() | Ecto.UUID.t()) :: Library.Track.t() | nil
  def first_track(%RecSet{id: id}), do: first_track(id)

  def first_track(set_id) when is_binary(set_id),
    do: set_id |> RecSetQuery.ordered_tracks() |> List.first()

  @doc """
  The track right after `current_track_id` in the set's current order, or nil if it
  is the last track or not a member. Queries the order fresh each call, so the player
  only needs to hold the pointer `(set_id, current_track_id)` — a reorder is honored
  automatically with no re-sync.
  """
  @spec next_after(RecSet.t() | Ecto.UUID.t(), Ecto.UUID.t()) :: Library.Track.t() | nil
  def next_after(%RecSet{id: id}, current_track_id), do: next_after(id, current_track_id)

  def next_after(set_id, current_track_id) when is_binary(set_id) do
    tracks = RecSetQuery.ordered_tracks(set_id)

    case Enum.find_index(tracks, &(&1.id == current_track_id)) do
      nil -> nil
      idx -> Enum.at(tracks, idx + 1)
    end
  end

  @doc """
  The Discotecagem console hint: the entry that follows `current_track_id` in the
  set's CURRENT order — its track, the incoming transition (with `from_ms` already
  clamped to the outgoing track's back half; never trusted blindly), and the
  playback facts a deck needs (effective BPM, duration, markers). Nil when current
  is last or not a member. Fresh-read every call: a pointer, never a plan.
  """
  @spec entry_after(Ecto.UUID.t(), Ecto.UUID.t()) :: map() | nil
  def entry_after(set_id, current_track_id) when is_binary(set_id) do
    entries = RecSetQuery.ordered_entries(set_id)

    with idx when is_integer(idx) <-
           Enum.find_index(entries, &(&1.track.id == current_track_id)),
         %{} = next <- Enum.at(entries, idx + 1) do
      build_hint(Enum.at(entries, idx).track, next)
    else
      _ -> nil
    end
  end

  defp build_hint(outgoing, %{track: track} = entry) do
    %{
      track: track,
      position: entry.position,
      role: entry.role,
      transition: clamp_transition(entry.transition, outgoing),
      bpm: Library.effective(track).bpm,
      outgoing_bpm: Library.effective(outgoing).bpm,
      duration_ms: track.duration_ms,
      markers: track.cue_points || []
    }
  end

  # Mid-song auto-outros are still persisted (the old "salto no meio"), so the
  # hint clamps from_ms to the outgoing track's back half and away from its tail;
  # a missing from_ms falls back to an end window. The client re-clamps against
  # the real media duration.
  defp clamp_transition(nil, _outgoing), do: nil

  defp clamp_transition(transition, %{duration_ms: dur}) when is_integer(dur) and dur > 0 do
    from = transition["from_ms"] || dur - @default_outro_window_ms

    clamped =
      from
      |> max(div(dur, 2))
      |> min(dur - @min_tail_ms)
      |> max(0)

    Map.put(transition, "from_ms", clamped)
  end

  defp clamp_transition(transition, _outgoing), do: transition

  @spec create(String.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def create(name), do: %RecSet{} |> RecSet.changeset(%{name: name}) |> Repo.insert()

  @spec rename(RecSet.t(), String.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def rename(set, name), do: set |> RecSet.changeset(%{name: name}) |> Repo.update()

  @doc "Sets the set's target style (genre-folder key) — the anchor for style scoring."
  @spec set_target_style(RecSet.t(), String.t() | nil) ::
          {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def set_target_style(set, key),
    do: set |> RecSet.changeset(%{target_style: key}) |> Repo.update()

  @spec delete(RecSet.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def delete(set), do: Repo.delete(set)

  @doc """
  Duplicates a set into a fresh `"<name> (cópia)"` — same target style and every
  entry copied verbatim (track, position, role, transition). A real backup: the
  copy and the original share no rows, so editing one never touches the other.
  """
  @spec duplicate(RecSet.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def duplicate(%RecSet{id: id}) do
    # Read the source fresh so a stale in-memory struct still copies the current
    # name/target_style/rows.
    %RecSet{name: name, target_style: style} = RecSetQuery.get(id)

    Repo.transact(fn ->
      with {:ok, copy} <-
             %RecSet{}
             |> RecSet.changeset(%{name: "#{name} (cópia)", target_style: style})
             |> Repo.insert() do
        copy_rows(id, copy.id)
        {:ok, copy}
      end
    end)
  end

  defp copy_rows(source_id, copy_id) do
    for row <- RecSetQuery.rows(source_id) do
      %SetTrack{}
      |> SetTrack.changeset(%{
        rec_set_id: copy_id,
        track_id: row.track_id,
        position: row.position,
        role: row.role,
        transition: row.transition
      })
      |> Repo.insert!()
    end
  end

  @doc """
  Appends a track to the end of the set (a no-op if it's already a member),
  optionally tagging it with a section `role` (e.g. `"pico"`).
  """
  @spec append(RecSet.t(), Library.Track.t(), String.t() | nil) ::
          {:ok, SetTrack.t()} | {:error, term()}
  def append(set, track, role \\ nil)

  def append(%RecSet{id: id} = set, track, role) do
    result = append_quiet(set, track, role)
    broadcast_set_changed(id)
    result
  end

  @doc """
  `append/3` without the broadcast — for batch orchestration (the Planner fills
  a whole set slot by slot). The batch owner broadcasts ONCE at the end; a
  per-row broadcast made every subscriber (the live console included) re-load
  the full entry list ~2× per planned track.
  """
  @spec append_quiet(RecSet.t(), Library.Track.t(), String.t() | nil) ::
          {:ok, SetTrack.t()} | {:error, term()}
  def append_quiet(%RecSet{id: id}, track, role \\ nil) do
    %SetTrack{}
    |> SetTrack.changeset(%{
      rec_set_id: id,
      track_id: track.id,
      position: RecSetQuery.count(id) + 1,
      role: role
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:rec_set_id, :track_id])
  end

  @doc "Removes every track from the set (a `:replace` plan clears before filling). Returns the set."
  @spec clear(RecSet.t()) :: RecSet.t()
  def clear(%RecSet{id: id} = set) do
    {_n, _} = SetTrack |> where([st], st.rec_set_id == ^id) |> Repo.delete_all()
    broadcast_set_changed(id)
    set
  end

  @doc "Distinct track ids already in ANY of the given sets — the cross-playlist dedup pool."
  @spec cross_set_track_ids([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def cross_set_track_ids(set_ids) when is_list(set_ids),
    do: set_ids |> Enum.reject(&is_nil/1) |> RecSetQuery.track_ids_in()

  def cross_set_track_ids(_), do: []

  @doc "Removes a track from the set and re-numbers the remaining positions."
  @spec remove(RecSet.t(), Library.Track.t()) :: :ok
  def remove(%RecSet{id: id} = set, track) do
    SetTrack
    |> where([st], st.rec_set_id == ^id and st.track_id == ^track.id)
    |> Repo.delete_all()

    reindex(set)
    broadcast_set_changed(id)
    :ok
  end

  @doc """
  Reorders a track in the set: `:up`/`:down` move one step (no-op at the edges),
  `:top`/`:bottom` jump it to the start/end. Positions are renumbered afterwards.
  """
  @spec move(RecSet.t(), Library.Track.t(), :up | :down | :top | :bottom) :: :ok
  def move(%RecSet{} = set, track, :top), do: reposition(set, track, 0)

  def move(%RecSet{id: id} = set, track, :bottom),
    do: reposition(set, track, RecSetQuery.count(id) + 1)

  def move(%RecSet{id: id}, track, direction) do
    rows = RecSetQuery.rows(id)
    idx = Enum.find_index(rows, &(&1.track_id == track.id))
    swap_idx = if idx, do: idx + step(direction)

    if idx && swap_idx in 0..(length(rows) - 1)//1 do
      swap_positions(Enum.at(rows, idx), Enum.at(rows, swap_idx))
      broadcast_set_changed(id)
    end

    :ok
  end

  defp step(:up), do: -1
  defp step(:down), do: 1

  defp swap_positions(a, b) do
    {:ok, _} =
      Repo.transact(fn ->
        pa = a.position
        a |> SetTrack.changeset(%{position: b.position}) |> Repo.update!()
        b |> SetTrack.changeset(%{position: pa}) |> Repo.update!()
        {:ok, :swapped}
      end)

    :ok
  end

  # Parks the track at an out-of-range position (0 = before all, count+1 = after all),
  # then renumbers — so it lands first/last.
  defp reposition(%RecSet{id: id} = set, track, position) do
    id
    |> RecSetQuery.row!(track.id)
    |> SetTrack.changeset(%{position: position})
    |> Repo.update()

    reindex(set)
    broadcast_set_changed(id)
    :ok
  end

  # ── Connections (transition INTO an entry, from the previous track) ──────────

  @doc """
  Suggests a transition for mixing `prev` into `this`: a `crossfade` (beat-aware)
  when both have outro/intro markers and effective BPMs within ~8%, an `echo`
  (echo-out — the delay tail masks the tempo jump) when the markers exist but
  tempos diverge, else a `cut`. `from_ms`/`to_ms` default to the outro(prev)/
  intro(this) markers (to_ms 0 when no intro). `fade` stays selectable manually.
  """
  @spec suggest_transition(Library.Track.t(), Library.Track.t()) :: map()
  def suggest_transition(prev, this) do
    out = Marker.outro(prev)
    intro = Marker.intro(this)
    a = Library.effective(prev)
    b = Library.effective(this)

    {type, reason} = TransitionChooser.choose(a, b, out, intro)

    %{
      "enabled" => true,
      "type" => type,
      # Por que o console escolheu esta transição — mostrado na UI para tirar o
      # "mistério" da remixagem automática.
      "reason" => reason,
      "from_ms" => out && out["ms"],
      "to_ms" => (intro && intro["ms"]) || 0
    }
  end

  @doc "Suggested transitions for every consecutive pair: `[{receiving_track_id, transition}]`."
  @spec suggest_all(RecSet.t()) :: [{Ecto.UUID.t(), map()}]
  def suggest_all(%RecSet{} = set) do
    set
    |> tracks()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, this] -> {this.id, suggest_transition(prev, this)} end)
  end

  @doc "Sets the incoming transition on the entry that receives it (the later track)."
  @spec connect(RecSet.t(), Library.Track.t(), map()) ::
          {:ok, SetTrack.t()} | {:error, Ecto.Changeset.t()}
  def connect(%RecSet{id: set_id} = set, track, attrs) do
    result = connect_quiet(set, track, attrs)
    broadcast_set_changed(set_id)
    result
  end

  defp connect_quiet(%RecSet{id: set_id}, %{id: track_id}, attrs) do
    set_id
    |> RecSetQuery.row!(track_id)
    |> SetTrack.changeset(%{transition: normalize_transition(attrs)})
    |> Repo.update()
  end

  @doc "Clears the incoming transition on an entry (back to plain sequential play)."
  @spec disconnect(RecSet.t(), Library.Track.t()) ::
          {:ok, SetTrack.t()} | {:error, Ecto.Changeset.t()}
  def disconnect(%RecSet{id: set_id}, %{id: track_id}) do
    result =
      set_id
      |> RecSetQuery.row!(track_id)
      |> SetTrack.changeset(%{transition: nil})
      |> Repo.update()

    broadcast_set_changed(set_id)
    result
  end

  @doc "Auto-connects every consecutive pair (suggest + persist); returns `{:ok, count}`."
  @spec connect_all(RecSet.t()) :: {:ok, non_neg_integer()}
  def connect_all(%RecSet{id: id} = set) do
    count = connect_pairs_quiet(set)
    broadcast_set_changed(id)
    {:ok, count}
  end

  defp connect_pairs_quiet(set) do
    pairs =
      set
      |> tracks()
      |> Enum.chunk_every(2, 1, :discard)

    Enum.each(pairs, fn [prev, this] ->
      {:ok, _} = connect_quiet(set, this, suggest_transition(prev, this))
    end)

    length(pairs)
  end

  defp normalize_transition(attrs) do
    type = attrs["type"] || attrs[:type]
    reason = attrs["reason"] || attrs[:reason]

    %{
      "enabled" => (attrs["enabled"] || attrs[:enabled]) != false,
      # An unknown type degrades to the SAFEST behavior (plain cut), never to an
      # overlap the engine would then execute with bogus parameters.
      "type" => if(type in @transition_types, do: type, else: "cut"),
      # Preserved when the console suggested it; nil for a hand-set transition.
      "reason" => reason,
      "from_ms" => attrs["from_ms"] || attrs[:from_ms],
      "to_ms" => attrs["to_ms"] || attrs[:to_ms] || 0
    }
  end

  @doc """
  Ranked candidates to append next: scored from the last track (or as an opening
  when the set is empty), anchored on the set's `target_style` and an optional
  `:target_intensity` (the active section's energy target). Excludes members.
  """
  @spec next_candidates(RecSet.t(), keyword()) :: [Mixing.suggestion()]
  def next_candidates(%RecSet{} = set, opts \\ []) do
    Mixing.rank(rank_opts(set, opts))
  end

  @doc """
  Opening candidates for an empty set: ranked by style + an opening-strength
  intensity + rating (no previous track, so no harmony/BPM).
  """
  @spec suggest_opening(RecSet.t(), keyword()) :: [Mixing.suggestion()]
  def suggest_opening(%RecSet{} = set, opts \\ []) do
    Mixing.rank(
      prev: nil,
      target_style: set.target_style,
      target_intensity:
        Keyword.get(opts, :target_intensity) || Mixing.target_intensity("abertura"),
      exclude: member_ids(set),
      limit: Keyword.get(opts, :limit, 10)
    )
  end

  @doc "Greedily appends up to `:count` (default 8) compatible tracks (style + harmony)."
  @spec auto_fill(RecSet.t(), keyword()) :: {:ok, RecSet.t()}
  def auto_fill(set, opts \\ []),
    do: {:ok, greedy_fill(set, Keyword.get(opts, :count, 8), nil, nil)}

  @doc """
  Fills a section: appends `count` tracks targeting the section role's energy,
  chained from the last track and anchored on the set's style. Each appended track
  is tagged with `role`. Stops early if no candidate remains.
  """
  @spec fill_section(RecSet.t(), String.t(), pos_integer()) :: {:ok, RecSet.t()}
  def fill_section(%RecSet{} = set, role, count) when is_integer(count) and count > 0,
    do: {:ok, greedy_fill(set, count, role, Mixing.target_intensity(role))}

  @doc "Configurable long-set planning presets read by the set-builder UI."
  @spec plan_presets() :: [map()]
  defdelegate plan_presets, to: Presets, as: :all

  @doc "Maximum number of tracks the planner accepts in one long-set run."
  @spec max_plan_tracks() :: pos_integer()
  defdelegate max_plan_tracks, to: Presets, as: :max_tracks

  @doc "The studio control values a preset pre-fills (allowed/excluded styles, arc shape)."
  @spec preset_fields(String.t()) :: %{
          allow_styles: [String.t()],
          exclude_styles: [String.t()],
          arc_shape: atom()
        }
  defdelegate preset_fields(key), to: Presets, as: :to_config_fields

  @doc """
  Plans (or extends) `set` from raw Planning-Studio form params: validates them
  into a `PlanConfig` and runs the `Planner` (energy arc → ranked, filtered,
  deduped fill → automatic transitions). Returns `{:ok, set}`.
  """
  @spec plan(RecSet.t(), map()) :: {:ok, RecSet.t()}
  def plan(%RecSet{} = set, params) when is_map(params),
    do: Planner.run(set, PlanConfig.from_params(params))

  @doc """
  Estimates how many tracks fill `minutes`, from the average duration of present
  library tracks that fit the preset (its excluded styles are left out of the mean).
  """
  @spec estimate_count_for_duration(pos_integer(), keyword()) :: pos_integer()
  def estimate_count_for_duration(minutes, opts \\ []) when is_integer(minutes) and minutes > 0 do
    preset = Presets.get(Keyword.get(opts, :preset, "custom"))

    track_ms = preset.exclude_styles |> TrackQuery.avg_present_duration_ms() |> duration_ms()

    minutes
    |> Kernel.*(60_000)
    |> Kernel./(track_ms)
    |> ceil()
    |> max(2)
    |> min(preset.max_tracks)
  end

  defp duration_ms(nil), do: 210_000
  defp duration_ms(%Decimal{} = value), do: Decimal.to_float(value)
  defp duration_ms(value), do: value

  @doc """
  Remixes an EXISTING set: keeps the same tracks but reorders them along the energy
  arc (`EnergyArc.plan/1`), giving each slot the remaining track whose intensity
  best fits and nudging "ouro" (gold) tracks toward the peaks so they spread across
  the highlights. Re-tags the arc roles and re-connects every pair. `{:ok, set}`.
  """
  @spec remix(RecSet.t()) :: {:ok, RecSet.t()}
  def remix(%RecSet{} = set) do
    cards =
      set
      |> tracks()
      |> Enum.map(&%{track: &1, intensity: Mixing.intensity(&1), gold: gold?(&1)})

    {:ok, _} =
      Repo.transact(fn ->
        cards
        |> length()
        |> EnergyArc.plan()
        |> assign_arc(cards)
        |> Enum.with_index(1)
        |> Enum.each(fn {{track, role}, pos} ->
          set.id
          |> RecSetQuery.row!(track.id)
          |> SetTrack.changeset(%{position: pos, role: role})
          |> Repo.update!()
        end)

        connect_pairs_quiet(set)
        {:ok, set}
      end)

    broadcast_set_changed(set.id)
    {:ok, set}
  end

  @remix_jitter 0.08

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
    |> Enum.filter(fn {_card, s} -> s >= best - @remix_jitter end)
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

  defp gold?(track), do: Beatgrid.Gold.gold?(track)

  defp greedy_fill(set, count, _role, _ti) when count <= 0, do: set

  defp greedy_fill(set, count, role, ti) do
    case Mixing.rank(rank_opts(set, target_intensity: ti, limit: 1)) do
      [%{track: next} | _] ->
        append(set, next, role)
        greedy_fill(set, count - 1, role, ti)

      [] ->
        set
    end
  end

  # Console opts forwarded as-is to Mixing.rank/1 (weights + hard filters).
  @passthrough [
    :weights,
    :harmonic_only,
    :bpm_min,
    :bpm_max,
    :min_rating,
    :exclude_styles,
    :limit
  ]

  # Common rank options: anchor on the set's style, chain from the last member,
  # and exclude everything already in the set. Console weights/filters
  # (`@passthrough`) flow through unchanged.
  defp rank_opts(%RecSet{} = set, opts) do
    members = RecSetQuery.ordered_tracks(set.id)

    base = [
      target_style: Keyword.get(opts, :target_style, set.target_style),
      target_intensity: Keyword.get(opts, :target_intensity),
      exclude: Enum.map(members, & &1.id),
      limit: Keyword.get(opts, :limit, 10)
    ]

    base =
      case List.last(members) do
        nil -> base
        last -> [{:prev, last} | base]
      end

    Keyword.merge(base, Keyword.take(opts, @passthrough))
  end

  defp member_ids(%RecSet{id: id}), do: RecSetQuery.ordered_tracks(id) |> Enum.map(& &1.id)

  @doc "Writes the set as an `.m3u` playlist under `<library_root>/_Sets`."
  @spec export_m3u(RecSet.t()) :: {:ok, Path.t()} | {:error, term()}
  def export_m3u(%RecSet{id: id, name: name}) do
    dir = Path.join(Library.library_root(), "_Sets")
    path = Path.join(dir, sanitize(name) <> ".m3u")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, m3u_body(RecSetQuery.ordered_tracks(id))) do
      {:ok, path}
    end
  end

  # --- internals ---

  defp reindex(%RecSet{id: id}) do
    {:ok, _} =
      Repo.transact(fn ->
        id
        |> RecSetQuery.rows()
        |> Enum.with_index(1)
        |> Enum.each(fn {row, position} ->
          row |> SetTrack.changeset(%{position: position}) |> Repo.update!()
        end)

        {:ok, :reindexed}
      end)

    :ok
  end

  defp m3u_body(tracks) do
    root = Library.library_root()
    lines = Enum.flat_map(tracks, &extinf(&1, root))
    Enum.join(["#EXTM3U" | lines], "\n") <> "\n"
  end

  defp extinf(track, root) do
    secs = if track.duration_ms, do: div(track.duration_ms, 1000), else: -1
    artist = track.tag_artist || "—"
    title = track.tag_title || track.filename
    ["#EXTINF:#{secs},#{artist} - #{title}", Path.join(root, track.rel_path)]
  end

  defp sanitize(name), do: (name || "set") |> String.replace(@unsafe, "-") |> String.trim()
end
