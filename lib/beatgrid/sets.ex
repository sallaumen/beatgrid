defmodule Beatgrid.Sets do
  @moduledoc """
  Scored set-builder. A `RecSet` is a named, ordered chain of tracks the user
  assembles for a gig, anchored on a `target_style`. Tracks are appended from the
  scored candidates (`Mixing.rank`, excluding members), section by section
  (`fill_section/3`) or greedily (`auto_fill/2`). A finished set exports to an
  `.m3u` playlist under `<library_root>/_Sets` that Serato/VLC read directly.
  """
  import Ecto.Query

  alias Beatgrid.Library
  alias Beatgrid.Library.Marker
  alias Beatgrid.Mixing
  alias Beatgrid.Repo
  alias Beatgrid.Sets.{RecSet, RecSetQuery, SetTrack}

  @transition_types ~w(cut fade crossfade)

  @unsafe ~r/[\/\\:*?"<>|]/u

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
  Appends a track to the end of the set (a no-op if it's already a member),
  optionally tagging it with a section `role` (e.g. `"pico"`).
  """
  @spec append(RecSet.t(), Library.Track.t(), String.t() | nil) ::
          {:ok, SetTrack.t()} | {:error, term()}
  def append(set, track, role \\ nil)

  def append(%RecSet{id: id}, track, role) do
    %SetTrack{}
    |> SetTrack.changeset(%{
      rec_set_id: id,
      track_id: track.id,
      position: RecSetQuery.count(id) + 1,
      role: role
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:rec_set_id, :track_id])
  end

  @doc "Removes a track from the set and re-numbers the remaining positions."
  @spec remove(RecSet.t(), Library.Track.t()) :: :ok
  def remove(%RecSet{id: id} = set, track) do
    SetTrack
    |> where([st], st.rec_set_id == ^id and st.track_id == ^track.id)
    |> Repo.delete_all()

    reindex(set)
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
    end

    :ok
  end

  defp step(:up), do: -1
  defp step(:down), do: 1

  defp swap_positions(a, b) do
    pa = a.position
    a |> SetTrack.changeset(%{position: b.position}) |> Repo.update()
    b |> SetTrack.changeset(%{position: pa}) |> Repo.update()
  end

  # Parks the track at an out-of-range position (0 = before all, count+1 = after all),
  # then renumbers — so it lands first/last.
  defp reposition(%RecSet{id: id} = set, track, position) do
    SetTrack
    |> Repo.get_by!(rec_set_id: id, track_id: track.id)
    |> SetTrack.changeset(%{position: position})
    |> Repo.update()

    reindex(set)
    :ok
  end

  # ── Connections (transition INTO an entry, from the previous track) ──────────

  @doc """
  Suggests a transition for mixing `prev` into `this`: a `crossfade` (beat-aware)
  when both have outro/intro markers and effective BPMs within ~8%, a `fade` when
  the markers exist but tempos diverge, else a `cut`. `from_ms`/`to_ms` default to
  the outro(prev)/intro(this) markers (to_ms 0 when no intro).
  """
  @spec suggest_transition(Library.Track.t(), Library.Track.t()) :: map()
  def suggest_transition(prev, this) do
    out = Marker.outro(prev)
    intro = Marker.intro(this)
    bpm_prev = Library.effective(prev).bpm
    bpm_this = Library.effective(this).bpm

    type =
      cond do
        is_nil(out) or is_nil(intro) -> "cut"
        bpm_close?(bpm_prev, bpm_this) -> "crossfade"
        true -> "fade"
      end

    %{
      "enabled" => true,
      "type" => type,
      "from_ms" => out && out["ms"],
      "to_ms" => (intro && intro["ms"]) || 0
    }
  end

  defp bpm_close?(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0,
    do: abs(a - b) / max(a, b) <= 0.08

  defp bpm_close?(_a, _b), do: false

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
  def connect(%RecSet{id: set_id}, %{id: track_id}, attrs) do
    Repo.get_by!(SetTrack, rec_set_id: set_id, track_id: track_id)
    |> SetTrack.changeset(%{transition: normalize_transition(attrs)})
    |> Repo.update()
  end

  @doc "Clears the incoming transition on an entry (back to plain sequential play)."
  @spec disconnect(RecSet.t(), Library.Track.t()) ::
          {:ok, SetTrack.t()} | {:error, Ecto.Changeset.t()}
  def disconnect(%RecSet{id: set_id}, %{id: track_id}) do
    Repo.get_by!(SetTrack, rec_set_id: set_id, track_id: track_id)
    |> SetTrack.changeset(%{transition: nil})
    |> Repo.update()
  end

  @doc "Auto-connects every consecutive pair (suggest + persist); returns `{:ok, count}`."
  @spec connect_all(RecSet.t()) :: {:ok, non_neg_integer()}
  def connect_all(%RecSet{} = set) do
    count =
      set
      |> tracks()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [prev, this] ->
        {:ok, _} = connect(set, this, suggest_transition(prev, this))
        true
      end)

    {:ok, count}
  end

  @doc """
  Builds a ~8-track example set from `forro_roots`: a `RecSet` "Roots — exemplo",
  seeded with a present roots track and harmonically auto-filled. Marker detection +
  connections are applied separately (see `Workers.ExampleSetWorker`). Returns
  `{:error, :no_roots_tracks}` when the folder has no present tracks.
  """
  @spec build_example() :: {:ok, RecSet.t()} | {:error, :no_roots_tracks}
  def build_example do
    case seed_roots_track() do
      nil ->
        {:error, :no_roots_tracks}

      seed ->
        {:ok, set} = create("Roots — exemplo")
        {:ok, set} = set_target_style(set, "forro_roots")
        append(set, seed)
        auto_fill(set, count: 7)
        {:ok, set}
    end
  end

  defp seed_roots_track do
    Repo.one(
      from t in Library.Track,
        where: t.status == :present and t.genre_folder == "forro_roots",
        order_by: [desc_nulls_last: t.analyzed_at],
        limit: 1
    )
  end

  defp normalize_transition(attrs) do
    type = attrs["type"] || attrs[:type]

    %{
      "enabled" => (attrs["enabled"] || attrs[:enabled]) != false,
      "type" => if(type in @transition_types, do: type, else: "crossfade"),
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

  @plan_topk 5
  @max_plan_tracks 240

  # Planning weights differ from the live console's: the energy arc (intensity) and
  # tempo continuity (bpm) lead, so respiros actually calm down and the tempo doesn't
  # jump — the user's "arco digno de DJ, reduzindo o tempo aos poucos". Style/harmony
  # still keep the set coherent and the transitions mixable.
  @plan_weights %{style: 20, harmony: 25, intensity: 35, bpm: 18, rating: 2}

  @plan_presets [
    %{
      key: "forro_roots_marathon",
      name: "Forro Roots Marathon",
      target_style: "forro_roots",
      max_tracks: @max_plan_tracks,
      exclude_styles: ["mpb", "forro_mpb"],
      description: "A long roots-first set with only close Forro material around it.",
      phases: [
        %{until: 1.0, target_style: "forro_roots"}
      ]
    },
    %{
      key: "roots_to_forro_mpb",
      name: "Roots to Forro MPB",
      target_style: "forro_roots",
      max_tracks: @max_plan_tracks,
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
      max_tracks: @max_plan_tracks,
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
      max_tracks: @max_plan_tracks,
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
      max_tracks: @max_plan_tracks,
      exclude_styles: ["forro_psicodelico"],
      description: "A dedicated MPB set, used only when explicitly selected.",
      phases: [
        %{until: 1.0, target_style: "mpb"}
      ]
    },
    %{
      key: "custom",
      name: "Custom",
      target_style: nil,
      max_tracks: @max_plan_tracks,
      exclude_styles: [],
      description: "Uses the set target style and manual constraints.",
      phases: [
        %{until: 1.0, target_style: nil}
      ]
    }
  ]

  @doc "Configurable long-set planning presets read by the set-builder UI."
  @spec plan_presets() :: [map()]
  def plan_presets, do: @plan_presets

  @doc "Maximum number of tracks the planner accepts in one long-set run."
  @spec max_plan_tracks() :: pos_integer()
  def max_plan_tracks, do: @max_plan_tracks

  @doc """
  Estimates how many tracks are needed to fill `minutes`, using the average
  duration of present library tracks that fit the selected preset.
  """
  @spec estimate_count_for_duration(pos_integer(), keyword()) :: pos_integer()
  def estimate_count_for_duration(minutes, opts \\ []) when is_integer(minutes) and minutes > 0 do
    preset = plan_preset(Keyword.get(opts, :preset, "custom"))
    exclude_styles = preset_exclude_styles(preset, opts)

    avg_ms =
      Library.Track
      |> where([t], t.status == :present)
      |> where([t], not is_nil(t.duration_ms) and t.duration_ms > 0)
      |> maybe_exclude_styles(exclude_styles)
      |> select([t], avg(t.duration_ms))
      |> Repo.one()

    track_ms = duration_ms(avg_ms)

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
  Plans a full set of `count` faixas along an energy arc (`Mixing.block_plan/1`):
  opener → peak↔respiro waves → fade-out. Each slot is filled by ranking candidates
  for its target intensity (chained from the previous faixa, anchored on the set's
  style, with the arc + tempo weighted to lead) and picking one at random among the
  top few — so the plan varies per call. Tags each faixa with its arc role, then
  connects every consecutive pair with a DJ transition. A slot with no remaining
  candidate is skipped. Returns `{:ok, set}`.
  """
  @spec plan_set(RecSet.t(), pos_integer(), keyword()) :: {:ok, RecSet.t()}
  def plan_set(%RecSet{} = set, count, opts \\ []) when is_integer(count) and count > 0 do
    topk = Keyword.get(opts, :topk, @plan_topk)
    preset = plan_preset(Keyword.get(opts, :preset, "custom"))
    count = count |> min(preset.max_tracks) |> max(1)

    count
    |> Mixing.block_plan()
    |> Enum.with_index()
    |> Enum.each(fn {slot, index} ->
      opts =
        rank_opts(set,
          target_style: phase_target_style(preset, index, count, set),
          target_intensity: slot.target_intensity,
          limit: topk,
          weights: @plan_weights,
          exclude_styles: preset_exclude_styles(preset, opts)
        )

      case Mixing.rank(opts) do
        [] -> :ok
        ranked -> append(set, Enum.random(ranked).track, slot.role)
      end
    end)

    connect_all(set)
    {:ok, set}
  end

  defp plan_preset(key) do
    Enum.find(@plan_presets, &(&1.key == key)) || Enum.find(@plan_presets, &(&1.key == "custom"))
  end

  defp phase_target_style(%{phases: phases}, index, count, set) do
    progress =
      if count <= 1 do
        1.0
      else
        index / (count - 1)
      end

    phase = Enum.find(phases, &(progress <= &1.until)) || List.last(phases)
    phase.target_style || set.target_style
  end

  defp preset_exclude_styles(preset, opts) do
    (preset.exclude_styles ++ Keyword.get(opts, :exclude_styles, [])) |> Enum.uniq()
  end

  defp maybe_exclude_styles(query, []), do: query

  defp maybe_exclude_styles(query, styles) do
    where(query, [t], t.genre_folder not in ^styles)
  end

  @doc """
  Remixes an EXISTING set: keeps the same tracks but reorders them along the energy
  arc (`Mixing.block_plan/1`), giving each slot the remaining track whose intensity
  best fits and nudging "ouro" (gold) tracks toward the peaks so they spread across
  the highlights. Re-tags the arc roles and re-connects every pair. `{:ok, set}`.
  """
  @spec remix(RecSet.t()) :: {:ok, RecSet.t()}
  def remix(%RecSet{} = set) do
    cards =
      set
      |> tracks()
      |> Enum.map(&%{track: &1, intensity: Mixing.intensity(&1), gold: gold?(&1)})

    cards
    |> length()
    |> Mixing.block_plan()
    |> assign_arc(cards)
    |> Enum.with_index(1)
    |> Enum.each(fn {{track, role}, pos} ->
      SetTrack
      |> Repo.get_by!(rec_set_id: set.id, track_id: track.id)
      |> SetTrack.changeset(%{position: pos, role: role})
      |> Repo.update()
    end)

    connect_all(set)
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

  defp gold?(track), do: track |> Library.gold() |> elem(0)

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
    id
    |> RecSetQuery.rows()
    |> Enum.with_index(1)
    |> Enum.each(fn {row, position} ->
      row |> SetTrack.changeset(%{position: position}) |> Repo.update()
    end)
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
