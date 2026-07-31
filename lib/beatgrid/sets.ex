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
    M3u,
    PlanConfig,
    Planner,
    Presets,
    RecSet,
    RecSetQuery,
    Remixer,
    SetTrack,
    TransitionChooser
  }

  @transition_types ~w(cut fade crossfade echo filter bass_swap brake lowpass scratch_cut spinback chirp transform scribble)

  # Console hint clamps (never-again #4: from_ms is never trusted blindly).
  @default_outro_window_ms 8_000
  @min_tail_ms 3_000
  @max_intro_skip_ms 10_000

  # A hand fire is only a CORRECTION when it departs this far from what the
  # console would already do — anything closer is noise, not a lesson.
  @learn_min_delta_ms 5_000

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
  set's CURRENT order — its track, the incoming transition (timing DERIVED here
  from both tracks' current markers; the row only stores the decision), and the
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

  @doc """
  Pre-trip check: walks the set's CURRENT entries and reports what would bite
  mid-set — missing files, tracks out of the library, no mix-out marker, no
  BPM. The console shows the list BEFORE the DJ leaves home.
  """
  @spec preflight(RecSet.t()) :: %{total: non_neg_integer(), issues: [map()]}
  def preflight(%RecSet{id: id}) do
    entries = RecSetQuery.ordered_entries(id)
    last = length(entries)

    issues =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, pos} -> entry_issues(entry.track, pos, last) end)
      |> Enum.reject(&(&1.problems == []))

    %{total: last, issues: issues}
  end

  defp entry_issues(track, pos, last) do
    checks = [
      arquivo_sumido: not File.exists?(Path.join(Library.library_root(), track.rel_path)),
      fora_da_biblioteca: track.status != :present,
      sem_saida: pos != last and is_nil(Marker.outro(track)),
      sem_bpm: is_nil(Library.effective(track).bpm)
    ]

    %{
      position: pos,
      title: track.tag_title || track.filename,
      problems: for({key, true} <- checks, do: key)
    }
  end

  defp build_hint(outgoing, %{track: track} = entry) do
    %{
      track: track,
      position: entry.position,
      role: entry.role,
      transition: hint_transition(entry.transition, outgoing, track),
      bpm: Library.effective(track).bpm,
      outgoing_bpm: Library.effective(outgoing).bpm,
      duration_ms: track.duration_ms,
      markers: track.cue_points || []
    }
  end

  # Timing comes from the tracks' CURRENT markers, never from the row: marker
  # re-analysis and hand edits reach the console instantly, and a reordered set
  # can't fire on a predecessor that no longer precedes it. A disabled row plays
  # as plain sequential. The client still re-clamps against real media duration.
  defp hint_transition(nil, _outgoing, _incoming), do: nil
  defp hint_transition(%{"enabled" => false}, _outgoing, _incoming), do: nil

  defp hint_transition(transition, outgoing, incoming) do
    timing = derived_timing(outgoing, incoming)

    transition
    |> Map.put("from_ms", learned_from(transition, outgoing) || timing.from_ms)
    |> Map.put("to_ms", timing.to_ms)
  end

  # O ponto que o DJ ensinou (um disparo real) vence o derivado dos marcadores;
  # só o clamp de cauda se aplica — o piso dos 70% protege contra marcador
  # automático ruim, não contra escolha humana.
  defp learned_from(%{"learned_from_ms" => ms}, %{duration_ms: dur})
       when is_integer(ms) and is_integer(dur) and dur > 0,
       do: ms |> min(dur - @min_tail_ms) |> max(0)

  defp learned_from(_transition, _outgoing), do: nil

  @doc """
  The fire/entry points the console will derive RIGHT NOW for mixing
  `outgoing` into `incoming` — current markers, clamped. What the set editor
  shows with this is exactly what the deck will do.
  """
  @spec derived_timing(Library.Track.t(), Library.Track.t()) ::
          %{from_ms: non_neg_integer() | nil, to_ms: non_neg_integer()}
  def derived_timing(outgoing, incoming) do
    %{from_ms: clamped_derived_from(outgoing), to_ms: derived_to_ms(incoming)}
  end

  @doc """
  What the console will actually do for this pair RIGHT NOW: marker-derived
  timing, with the DJ-taught point (when the receiving entry carries one)
  winning on the exit side. `learned?` lets the editor badge the pair.
  """
  @spec pair_timing(Library.Track.t(), %{track: Library.Track.t(), transition: map() | nil}) ::
          %{from_ms: non_neg_integer() | nil, to_ms: non_neg_integer(), learned?: boolean()}
  def pair_timing(outgoing, %{track: incoming, transition: transition}) do
    timing = derived_timing(outgoing, incoming)

    case learned_from(transition || %{}, outgoing) do
      nil -> Map.put(timing, :learned?, false)
      ms -> %{from_ms: ms, to_ms: timing.to_ms, learned?: true}
    end
  end

  defp clamped_derived_from(outgoing) do
    %{"from_ms" => from} = clamp_from(%{"from_ms" => derived_from_ms(outgoing)}, outgoing)
    from
  end

  defp derived_from_ms(outgoing) do
    case Marker.outro(outgoing) do
      %{"ms" => ms} when is_integer(ms) -> ms
      _missing -> nil
    end
  end

  # Skip a short breath at the head; a LONG quiet opening is real music (live/
  # acoustic intros measured only 6-8dB under the chorus), so play it from 0.
  defp derived_to_ms(incoming) do
    case Marker.intro(incoming) do
      %{"ms" => ms} when is_integer(ms) and ms <= @max_intro_skip_ms -> ms
      _long_or_missing -> 0
    end
  end

  defp clamp_from(transition, %{duration_ms: dur}) when is_integer(dur) and dur > 0 do
    from =
      transition["from_ms"]
      |> trusted_from(dur)
      |> min(dur - @min_tail_ms)
      |> max(0)

    Map.put(transition, "from_ms", from)
  end

  defp clamp_from(transition, _outgoing), do: transition

  # An outro in the front 70% of the track is noise (the old "salto no meio"),
  # not a mix-out point — fall back to the end window, same as no marker at all.
  defp trusted_from(from, dur) when is_integer(from) and from * 10 >= dur * 7, do: from
  defp trusted_from(_untrusted, dur), do: dur - @default_outro_window_ms

  @spec create(String.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def create(name), do: %RecSet{} |> RecSet.changeset(%{name: name}) |> Repo.insert()

  @doc """
  Creates a set already filled with `tracks` in order and every consecutive pair
  connected — one transaction, one broadcast. The playlist-import flow (and any
  future "turn this list into a set") gets all-or-nothing semantics for free.
  """
  @spec create_filled(String.t() | nil, [Library.Track.t()]) ::
          {:ok, RecSet.t()} | {:error, term()}
  def create_filled(name, tracks) do
    with {:ok, set} <- Repo.transact(fn -> insert_filled(name, tracks) end) do
      broadcast_set_changed(set.id)
      {:ok, set}
    end
  end

  defp insert_filled(name, tracks) do
    with {:ok, set} <- create(name),
         :ok <- append_all_quiet(set, tracks),
         {:ok, _count} <- connect_all_quiet(set) do
      {:ok, set}
    end
  end

  defp append_all_quiet(set, tracks) do
    Enum.reduce_while(tracks, :ok, fn track, :ok ->
      case append_quiet(set, track) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

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

  The position is claimed under a row lock on the set: concurrent appends (two
  tabs, console + planner) serialize instead of both reading the same tail, and
  `max + 1` stays correct after a library deletion cascades a hole that `count`
  would land on.
  """
  @spec append_quiet(RecSet.t(), Library.Track.t(), String.t() | nil) ::
          {:ok, SetTrack.t()} | {:error, term()}
  def append_quiet(%RecSet{id: id}, track, role \\ nil) do
    Repo.transact(fn ->
      RecSetQuery.lock(id)

      %SetTrack{}
      |> SetTrack.changeset(%{
        rec_set_id: id,
        track_id: track.id,
        position: RecSetQuery.max_position(id) + 1,
        role: role
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:rec_set_id, :track_id])
    end)
  end

  @doc "Removes every track from the set. Returns the set."
  @spec clear(RecSet.t()) :: RecSet.t()
  def clear(%RecSet{id: id} = set) do
    cleared = clear_quiet(set)
    broadcast_set_changed(id)
    cleared
  end

  @doc "`clear/1` without the broadcast — a `:replace` plan clears inside its transaction."
  @spec clear_quiet(RecSet.t()) :: RecSet.t()
  def clear_quiet(%RecSet{id: id} = set) do
    {_n, _} = SetTrack |> where([st], st.rec_set_id == ^id) |> Repo.delete_all()
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
  tempos diverge, else a `cut`. A suggestion is a DECISION (type/reason); the
  fire timing is derived from current markers when the console asks for a hint.
  `fade` stays selectable manually.
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
      "reason" => reason
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

  @doc """
  Sets the incoming transition on the entry that receives it (the later track).
  A track no longer in the set (edited elsewhere) is an error, not a crash.
  """
  @spec connect(RecSet.t(), Library.Track.t(), map()) ::
          {:ok, SetTrack.t()} | {:error, :not_a_member | Ecto.Changeset.t()}
  def connect(%RecSet{id: set_id} = set, track, attrs) do
    with {:ok, row} <- connect_quiet(set, track, attrs) do
      broadcast_set_changed(set_id)
      {:ok, row}
    end
  end

  defp connect_quiet(%RecSet{id: set_id}, %{id: track_id}, attrs) do
    with {:ok, row} <- RecSetQuery.fetch_row(set_id, track_id) do
      row
      |> SetTrack.changeset(%{transition: normalize_transition(attrs)})
      |> Repo.update()
    end
  end

  @doc "Clears the incoming transition on an entry (back to plain sequential play)."
  @spec disconnect(RecSet.t(), Library.Track.t()) ::
          {:ok, SetTrack.t()} | {:error, :not_a_member | Ecto.Changeset.t()}
  def disconnect(%RecSet{id: set_id}, %{id: track_id}) do
    with {:ok, row} <- RecSetQuery.fetch_row(set_id, track_id),
         {:ok, updated} <- row |> SetTrack.changeset(%{transition: nil}) |> Repo.update() do
      broadcast_set_changed(set_id)
      {:ok, updated}
    end
  end

  @doc """
  Records where the DJ ACTUALLY fired `from_track` into `receiving_track` (the T
  key, or the AUTO window after postponing): the point persists as
  `"learned_from_ms"` on the receiving entry and wins over marker-derived timing
  from then on. Returns `:ignored` when the pair isn't consecutive in the
  CURRENT order, the connection is off, the fire landed in the front half of
  the outgoing track (that's a skip, not a mix-out), or it's within 5s of what
  the console would already do. Re-suggesting or re-typing the pair wipes the
  learning — a fresh decision restarts from markers.
  """
  @spec learn_fire_point(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), integer()) ::
          {:ok, non_neg_integer()} | :ignored
  def learn_fire_point(set_id, receiving_track_id, from_track_id, at_ms)
      when is_binary(set_id) and is_integer(at_ms) do
    entries = RecSetQuery.ordered_entries(set_id)
    idx = Enum.find_index(entries, &(&1.track.id == receiving_track_id))

    with true <- is_integer(idx) and idx > 0,
         %{track: %{id: ^from_track_id} = outgoing} <- Enum.at(entries, idx - 1),
         %{transition: %{"enabled" => true} = transition} <- Enum.at(entries, idx),
         true <- learnable?(at_ms, transition, outgoing) do
      persist_learned(set_id, receiving_track_id, transition, at_ms)
    else
      _not_learnable -> :ignored
    end
  end

  defp learnable?(at_ms, transition, %{duration_ms: dur} = outgoing)
       when is_integer(dur) and dur > 0 do
    current = learned_from(transition, outgoing) || clamped_derived_from(outgoing)

    at_ms * 2 >= dur and at_ms < dur and abs(at_ms - current) >= @learn_min_delta_ms
  end

  defp learnable?(_at_ms, _transition, _outgoing), do: false

  defp persist_learned(set_id, track_id, transition, at_ms) do
    with {:ok, row} <- RecSetQuery.fetch_row(set_id, track_id),
         {:ok, _row} <-
           row
           |> SetTrack.changeset(%{transition: Map.put(transition, "learned_from_ms", at_ms)})
           |> Repo.update() do
      broadcast_set_changed(set_id)
      {:ok, at_ms}
    else
      _gone -> :ignored
    end
  end

  @doc "Auto-connects every consecutive pair (suggest + persist); returns `{:ok, count}`."
  @spec connect_all(RecSet.t()) :: {:ok, non_neg_integer()}
  def connect_all(%RecSet{id: id} = set) do
    {:ok, count} = connect_all_quiet(set)
    broadcast_set_changed(id)
    {:ok, count}
  end

  @doc "`connect_all/1` without the broadcast — for batch owners that notify once at the end."
  @spec connect_all_quiet(RecSet.t()) :: {:ok, non_neg_integer()}
  def connect_all_quiet(%RecSet{} = set), do: {:ok, connect_pairs_quiet(set)}

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

  # Only the DECISION persists (enabled/type/reason); timing keys are dropped —
  # they froze marker positions from plan day and went stale (the "Tramontina"
  # root cause). Legacy rows may still carry them; hints always overwrite.
  # "learned_from_ms" (a REAL fire the DJ performed) is the one exception, and
  # even it is wiped here: re-deciding a pair restarts from markers.
  defp normalize_transition(attrs) do
    type = attrs["type"] || attrs[:type]
    reason = attrs["reason"] || attrs[:reason]

    %{
      "enabled" => Map.get(attrs, "enabled", Map.get(attrs, :enabled, true)) != false,
      # An unknown type degrades to the SAFEST behavior (plain cut), never to an
      # overlap the engine would then execute with bogus parameters.
      "type" => if(type in @transition_types, do: type, else: "cut"),
      # Preserved when the console suggested it; nil for a hand-set transition.
      "reason" => reason
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
  def auto_fill(%RecSet{} = set, opts \\ []) do
    filled = greedy_fill(set, Keyword.get(opts, :count, 8), nil, nil)
    broadcast_set_changed(set.id)
    {:ok, filled}
  end

  @doc """
  Fills a section: appends `count` tracks targeting the section role's energy,
  chained from the last track and anchored on the set's style. Each appended track
  is tagged with `role`. Stops early if no candidate remains.
  """
  @spec fill_section(RecSet.t(), String.t(), pos_integer()) :: {:ok, RecSet.t()}
  def fill_section(%RecSet{} = set, role, count) when is_integer(count) and count > 0 do
    filled = greedy_fill(set, count, role, Mixing.target_intensity(role))
    broadcast_set_changed(set.id)
    {:ok, filled}
  end

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
  deduped fill → automatic transitions). The whole plan is one transaction, so
  a `:replace` that fails mid-fill rolls back to the untouched set instead of
  committing the clear and losing it. Subscribers hear one broadcast, after commit.
  """
  @spec plan(RecSet.t(), map()) :: {:ok, RecSet.t()} | {:error, term()}
  def plan(%RecSet{id: id} = set, params) when is_map(params) do
    with {:ok, planned} <-
           Repo.transact(fn -> Planner.run(set, PlanConfig.from_params(params)) end) do
      broadcast_set_changed(id)
      {:ok, planned}
    end
  end

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
  arc (`Remixer.order/1`), giving each slot the remaining track whose intensity
  best fits and nudging "ouro" (gold) tracks toward the peaks so they spread across
  the highlights. Re-tags the arc roles and re-connects every pair. `{:ok, set}`.
  """
  @spec remix(RecSet.t()) :: {:ok, RecSet.t()}
  def remix(%RecSet{} = set) do
    ordered =
      set
      |> tracks()
      |> Enum.map(&%{track: &1, intensity: Mixing.intensity(&1), gold: Beatgrid.Gold.gold?(&1)})
      |> Remixer.order()

    {:ok, _} =
      Repo.transact(fn ->
        ordered
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

  defp greedy_fill(set, count, _role, _ti) when count <= 0, do: set

  defp greedy_fill(set, count, role, ti) do
    case Mixing.rank(rank_opts(set, target_intensity: ti, limit: 1)) do
      [%{track: next} | _] ->
        {:ok, _} = append_quiet(set, next, role)
        greedy_fill(set, count - 1, role, ti)

      [] ->
        set
    end
  end

  @passthrough [
    :weights,
    :harmonic_only,
    :bpm_min,
    :bpm_max,
    :min_rating,
    :exclude_styles,
    :limit
  ]

  # Anchor on the set's style, chain from the last member, exclude every member;
  # console weights/filters (`@passthrough`) flow through unchanged.
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
    root = Library.library_root()
    dir = Path.join(root, "_Sets")
    path = Path.join(dir, M3u.filename(name))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, M3u.body(RecSetQuery.ordered_tracks(id), root)) do
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
end
