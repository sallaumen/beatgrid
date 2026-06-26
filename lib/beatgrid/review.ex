defmodule Beatgrid.Review do
  @moduledoc """
  Backend for the Central de Revisão. It aggregates the two suggestion queues
  (renames and AI classifications), records the user's per-card decisions
  (approve / reject / edit), and applies every approved suggestion to disk in one
  batch — renaming files, moving them into genre folders, and writing the ID3
  genre tag — logging each change to `Beatgrid.Operations` so the whole batch is
  reversible with `Operations.undo_batch/1`.

  Decisions dispatch on the suggestion struct, so callers can hand a
  `RenameSuggestion` or a `MoveSuggestion` to the same function.
  """
  alias Beatgrid.AI
  alias Beatgrid.Library
  alias Beatgrid.Library.{NameSync, RenameSuggestion, Track, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Organization
  alias Beatgrid.Organization.MoveSuggestion
  alias Beatgrid.Soundcharts
  alias Beatgrid.Tagging

  # A classification confidence at/above this is considered "high".
  @high_confidence 0.8

  # Batch size for the AI re-evaluation (mirrors AI classification batching).
  @reevaluate_batch 15

  # Suggestions still in the review queue (not yet applied/undone/failed).
  @open ~w(pending approved rejected)a

  # ---- listing (track preloaded for the cards) ----

  @spec queue_renames() :: [RenameSuggestion.t()]
  def queue_renames, do: NameSync.list_by(statuses: @open, preload: [track: :soundcharts_song])

  @spec queue_classifications() :: [MoveSuggestion.t()]
  def queue_classifications,
    do:
      Organization.list_by(statuses: @open, source: :claude, preload: [track: :soundcharts_song])

  @doc "Pending counts per tab, for the live badges."
  @spec counts() :: %{renames: non_neg_integer(), classifications: non_neg_integer()}
  def counts do
    %{
      renames: NameSync.count(status: :pending),
      classifications: Organization.count(status: :pending, source: :claude)
    }
  end

  # ---- per-card decisions (reversible; neutral = pending) ----

  @spec approve(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def approve(suggestion), do: set_status(suggestion, :approved)

  @spec reject(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def reject(suggestion), do: set_status(suggestion, :rejected)

  @spec reset(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def reset(suggestion), do: set_status(suggestion, :pending)

  @spec edit(struct(), String.t()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def edit(%RenameSuggestion{} = s, to), do: NameSync.edit_to(s, to)
  def edit(%MoveSuggestion{} = s, to), do: Organization.edit_to(s, to)

  defp set_status(%RenameSuggestion{} = s, status), do: NameSync.set_status(s, status)
  defp set_status(%MoveSuggestion{} = s, status), do: Organization.set_status(s, status)

  @doc "Approves every pending high-confidence suggestion in the given tab."
  @spec approve_high_confidence(:renames | :classifications) :: :ok
  def approve_high_confidence(:renames) do
    [status: :pending, confidence: :high]
    |> NameSync.list_by()
    |> Enum.each(&approve/1)
  end

  def approve_high_confidence(:classifications) do
    [status: :pending, source: :claude]
    |> Organization.list_by()
    |> Enum.filter(&high_confidence?/1)
    |> Enum.each(&approve/1)
  end

  defp high_confidence?(%MoveSuggestion{confidence: c}), do: is_float(c) and c >= @high_confidence

  # ---- audit-tab actions ----

  @doc "Clears the `[audit:...]` flag from a rename's reason (it leaves the Auditoria tab)."
  @spec dismiss_audit(RenameSuggestion.t()) ::
          {:ok, RenameSuggestion.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_audit(%RenameSuggestion{reason: reason} = suggestion) do
    NameSync.set_reason(suggestion, strip_audit(reason))
  end

  defp strip_audit(nil), do: nil
  defp strip_audit(reason), do: Regex.replace(~r/^\[audit:[^\]]+\]\s*/, reason, "")

  @doc "Moves the suggestion's track into `_Quarantine` and rejects the (now moot) suggestion."
  @spec quarantine_track(RenameSuggestion.t()) :: {:ok, RenameSuggestion.t()} | {:error, term()}
  def quarantine_track(%RenameSuggestion{} = suggestion) do
    with %Track{} = track <- Tracks.get(suggestion.track_id),
         {:ok, _quarantined} <- Library.quarantine(track) do
      NameSync.set_status(suggestion, :rejected)
    end
  end

  @doc """
  Re-runs Soundcharts matching for a suspect (audit-flagged) rename: rejects the
  suspect suggestion and, on a fresh match, re-proposes a rename from it. Spends
  Soundcharts quota. Returns `{:ok, :resolved | :no_match}` or `{:error, term}`.
  """
  @spec re_resolve(RenameSuggestion.t()) :: {:ok, :resolved | :no_match} | {:error, term()}
  def re_resolve(%RenameSuggestion{} = suggestion) do
    case Tracks.get(suggestion.track_id) do
      nil -> {:error, :track_not_found}
      track -> do_re_resolve(suggestion, track)
    end
  end

  defp do_re_resolve(suggestion, track) do
    case Soundcharts.re_resolve(track) do
      {:ok, _song} ->
        NameSync.set_status(suggestion, :rejected)
        NameSync.repropose(Tracks.get(track.id))
        {:ok, :resolved}

      {:error, :no_match} ->
        NameSync.set_status(suggestion, :rejected)
        {:ok, :no_match}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- apply every approved suggestion to disk, logged & reversible ----

  @doc "Re-evaluates every pending rename with the AI verifier (quota-free)."
  @spec reevaluate_all_renames() :: {:ok, %{updated: non_neg_integer()}} | {:error, term()}
  def reevaluate_all_renames do
    [status: :pending, preload: [track: :soundcharts_song]] |> NameSync.list_by() |> reevaluate()
  end

  @doc "Re-evaluates the open rename suggestions whose ids are given."
  @spec reevaluate_renames([Ecto.UUID.t()]) ::
          {:ok, %{updated: non_neg_integer()}} | {:error, term()}
  def reevaluate_renames(ids) when is_list(ids) do
    set = MapSet.new(ids)

    [status: :pending, preload: [track: :soundcharts_song]]
    |> NameSync.list_by()
    |> Enum.filter(&MapSet.member?(set, &1.id))
    |> reevaluate()
  end

  @doc "Re-evaluates the open rename suggestions of a single track (used after enrich)."
  @spec reevaluate_track(Ecto.UUID.t()) :: {:ok, %{updated: non_neg_integer()}} | {:error, term()}
  def reevaluate_track(track_id) do
    [status: :pending, preload: [track: :soundcharts_song]]
    |> NameSync.list_by()
    |> Enum.filter(&(&1.track_id == track_id))
    |> reevaluate()
  end

  defp reevaluate([]), do: {:ok, %{updated: 0}}

  defp reevaluate(suggestions) do
    updated =
      suggestions
      |> Enum.chunk_every(@reevaluate_batch)
      |> Enum.reduce(0, fn chunk, acc ->
        case AI.resolve_names(Enum.map(chunk, & &1.track)) do
          {:ok, results} ->
            by_id = Map.new(results, &{&1.track.id, &1})
            acc + Enum.count(chunk, &apply_resolution(&1, by_id[&1.track_id]))

          {:error, _reason} ->
            acc
        end
      end)

    {:ok, %{updated: updated}}
  end

  defp apply_resolution(_suggestion, nil), do: false

  defp apply_resolution(suggestion, r) do
    ext = Path.extname(suggestion.track.filename)
    song = suggestion.track.soundcharts_song

    to =
      if r.same_recording and song,
        do: NameSync.canonical_filename(song.credit_name, song.name, ext),
        else: NameSync.canonical_filename(r.artist, r.title, ext)

    with {:ok, _} <-
           NameSync.refine(suggestion, %{
             to_filename: to,
             rationale: r.rationale,
             confidence: confidence_atom(r.confidence)
           }),
         {:ok, _} <- Tracks.update(suggestion.track, %{sc_art_trusted: r.same_recording}) do
      true
    else
      _ -> false
    end
  end

  defp confidence_atom(c) when is_number(c) and c >= 0.8, do: :high
  defp confidence_atom(c) when is_number(c) and c >= 0.5, do: :medium
  defp confidence_atom(_), do: :low

  @doc """
  Applies all approved renames and classifications in one operations batch and
  returns the batch id with the applied/failed counts. Each classification also
  writes the genre tag. Use `Operations.undo_batch/1` with the returned id to
  reverse everything.
  """
  @spec apply_approved() ::
          {:ok, %{batch_id: Ecto.UUID.t(), applied: non_neg_integer(), failed: non_neg_integer()}}
  def apply_approved do
    apply_all(
      NameSync.list_by(status: :approved),
      Organization.list_by(status: :approved, source: :claude)
    )
  end

  @doc """
  Applies just the suggestions whose ids are in `ids` (renames and/or
  classifications), in one reversible operations batch. This backs the review
  screen's checkbox flow: selection is ephemeral in the UI, so nothing is written
  until the user applies — the chosen ids are resolved against the open queue here.
  Same return shape as `apply_approved/0`.
  """
  @spec apply_selected([Ecto.UUID.t()]) ::
          {:ok, %{batch_id: Ecto.UUID.t(), applied: non_neg_integer(), failed: non_neg_integer()}}
  def apply_selected(ids) when is_list(ids) do
    selected = MapSet.new(ids)

    apply_all(
      [statuses: @open] |> NameSync.list_by() |> Enum.filter(&MapSet.member?(selected, &1.id)),
      [statuses: @open, source: :claude]
      |> Organization.list_by()
      |> Enum.filter(&MapSet.member?(selected, &1.id))
    )
  end

  defp apply_all(renames, classifications) do
    batch_id = Uniq.UUID.uuid7()

    results =
      Enum.map(renames, &apply_rename(&1, batch_id)) ++
        Enum.map(classifications, &apply_classification(&1, batch_id))

    {:ok,
     %{
       batch_id: batch_id,
       applied: Enum.count(results, &(&1 == :ok)),
       failed: Enum.count(results, &(&1 == :failed))
     }}
  end

  defp apply_rename(suggestion, batch_id) do
    case NameSync.apply_batch([suggestion]) do
      {:ok, %{applied: 1}} ->
        record(suggestion.track_id, :rename, suggestion.from_filename, suggestion.to_filename,
          batch_id: batch_id,
          suggestion_id: suggestion.id
        )

        :ok

      _ ->
        :failed
    end
  end

  defp apply_classification(suggestion, batch_id) do
    previous_genre = with %{tag_genre: g} <- Tracks.get(suggestion.track_id), do: g

    case Organization.apply_batch([suggestion]) do
      {:ok, %{applied: 1}} ->
        record(suggestion.track_id, :move, suggestion.from_rel_path, suggestion.to_genre_folder,
          batch_id: batch_id,
          suggestion_id: suggestion.id
        )

        write_genre_tag(suggestion.track_id, previous_genre, batch_id)
        :ok

      _ ->
        :failed
    end
  end

  defp write_genre_tag(track_id, previous_genre, batch_id) do
    case Tagging.write_genre(Tracks.get(track_id)) do
      {:ok, tagged} ->
        record(track_id, :tag, previous_genre, tagged.tag_genre, batch_id: batch_id)

      _ ->
        :ok
    end
  end

  defp record(track_id, kind, from, to, opts) do
    Operations.record(%{
      track_id: track_id,
      kind: kind,
      from: from,
      to: to,
      batch_id: opts[:batch_id],
      suggestion_id: opts[:suggestion_id]
    })
  end
end
