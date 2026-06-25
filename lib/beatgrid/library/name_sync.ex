defmodule Beatgrid.Library.NameSync do
  @moduledoc """
  Syncs file names to the canonical `"Artist - Title"` derived from the linked
  Soundcharts song. High-confidence matches are auto-renamed; the rest become
  pending `RenameSuggestion`s for review. Every rename goes through
  `Library.rename/2` (disk move + row update) and is reversible via `undo/1`.
  """
  import Ecto.Query

  alias Beatgrid.Library
  alias Beatgrid.Library.{RenameSuggestion, RenameSuggestionQuery, Track, Tracks}
  alias Beatgrid.Repo

  @unsafe ~r/[\/\\:*?"<>|]/u
  @spaces ~r/\s+/u

  @doc ~S(Canonical filename `"<artist> - <title><ext>"`, filesystem-sanitized.)
  @spec canonical_filename(String.t(), String.t(), String.t()) :: String.t()
  def canonical_filename(credit_name, name, ext) do
    base =
      "#{credit_name} - #{name}"
      |> String.replace(@unsafe, "-")
      |> String.replace(@spaces, " ")
      |> String.trim()

    base <> ext
  end

  @spec get(Ecto.UUID.t()) :: RenameSuggestion.t() | nil
  def get(id), do: Repo.get(RenameSuggestion, id)

  @spec list_by(keyword()) :: [RenameSuggestion.t()]
  def list_by(opts \\ []), do: RenameSuggestionQuery.list_by(opts)

  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []), do: RenameSuggestionQuery.count(opts)

  @doc """
  Creates a pending rename suggestion for each resolved present track whose file
  name differs from its canonical name. Skips tracks already pending. Returns the
  batch id and count.
  """
  @spec propose() :: {:ok, %{batch_id: Ecto.UUID.t(), created: non_neg_integer()}}
  def propose do
    batch_id = Uniq.UUID.uuid7()
    pending = MapSet.new(RenameSuggestionQuery.list_by(status: :pending), & &1.track_id)

    created =
      Enum.reduce(resolved_tracks(), 0, fn track, count ->
        canonical = canonical_for(track)

        cond do
          is_nil(canonical) -> count
          canonical == track.filename -> count
          MapSet.member?(pending, track.id) -> count
          true -> create_suggestion(track, canonical, batch_id) && count + 1
        end
      end)

    {:ok, %{batch_id: batch_id, created: created}}
  end

  @doc "Applies every pending high-confidence suggestion (auto-rename). Returns counts."
  @spec apply_auto() :: {:ok, %{applied: non_neg_integer(), failed: non_neg_integer()}}
  def apply_auto do
    [status: :pending, confidence: :high]
    |> RenameSuggestionQuery.list_by()
    |> apply_batch()
  end

  @doc "Applies the given suggestions; one failure doesn't abort the batch."
  @spec apply_batch([RenameSuggestion.t()]) ::
          {:ok, %{applied: non_neg_integer(), failed: non_neg_integer()}}
  def apply_batch(suggestions) do
    results = Enum.map(suggestions, &apply_one/1)

    {:ok,
     %{
       applied: Enum.count(results, &(&1 == :applied)),
       failed: Enum.count(results, &(&1 == :failed))
     }}
  end

  @doc "Sets a suggestion's review status (approve/reject/reset)."
  @spec set_status(RenameSuggestion.t(), atom()) ::
          {:ok, RenameSuggestion.t()} | {:error, Ecto.Changeset.t()}
  def set_status(suggestion, status), do: update_status(suggestion, status)

  @doc "Edits the proposed file name and marks the suggestion approved."
  @spec edit_to(RenameSuggestion.t(), String.t()) ::
          {:ok, RenameSuggestion.t()} | {:error, Ecto.Changeset.t()}
  def edit_to(suggestion, to_filename) do
    suggestion
    |> RenameSuggestion.changeset(%{to_filename: to_filename, status: :approved})
    |> Repo.update()
  end

  @doc "Replaces a suggestion's reason (used to dismiss an audit flag)."
  @spec set_reason(RenameSuggestion.t(), String.t() | nil) ::
          {:ok, RenameSuggestion.t()} | {:error, Ecto.Changeset.t()}
  def set_reason(suggestion, reason) do
    suggestion |> RenameSuggestion.changeset(%{reason: reason}) |> Repo.update()
  end

  @doc """
  Creates a fresh pending suggestion for a single track from its current match
  (used after a re-resolve). Returns `{:ok, :no_change}` when the file name
  already matches the canonical or the track has no usable match.
  """
  @spec repropose(Track.t()) :: {:ok, RenameSuggestion.t()} | {:ok, :no_change}
  def repropose(track) do
    track = Repo.preload(track, :soundcharts_song)
    canonical = canonical_for(track)

    cond do
      is_nil(canonical) -> {:ok, :no_change}
      canonical == track.filename -> {:ok, :no_change}
      true -> {:ok, create_suggestion(track, canonical, Uniq.UUID.uuid7())}
    end
  end

  @doc "Reverses an applied rename, restoring the original file name."
  @spec undo(RenameSuggestion.t()) :: {:ok, RenameSuggestion.t()} | {:error, term()}
  def undo(%RenameSuggestion{status: :applied} = suggestion) do
    with %Track{} = track <- Tracks.get(suggestion.track_id),
         {:ok, _moved} <- Library.rename(track, suggestion.from_filename) do
      update_status(suggestion, :undone)
    end
  end

  def undo(%RenameSuggestion{}), do: {:error, :not_applied}

  # --- internals ---

  defp resolved_tracks do
    Track
    |> where([t], not is_nil(t.soundcharts_song_id) and t.status == :present)
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  defp canonical_for(%Track{soundcharts_song: %{credit_name: credit, name: name}} = track)
       when is_binary(credit) and is_binary(name) do
    canonical_filename(credit, name, Path.extname(track.filename))
  end

  defp canonical_for(_track), do: nil

  defp create_suggestion(track, canonical, batch_id) do
    song = track.soundcharts_song

    %RenameSuggestion{}
    |> RenameSuggestion.changeset(%{
      track_id: track.id,
      from_rel_path: track.rel_path,
      from_filename: track.filename,
      to_filename: canonical,
      confidence: track.sc_match_confidence,
      reason: "soundcharts: #{song.credit_name} - #{song.name}",
      status: :pending,
      batch_id: batch_id
    })
    |> Repo.insert!()
  end

  defp apply_one(suggestion) do
    with %Track{} = track <- Tracks.get(suggestion.track_id),
         {:ok, _moved} <- Library.rename(track, suggestion.to_filename) do
      mark_applied(suggestion)
      :applied
    else
      error ->
        mark_failed(suggestion, error)
        :failed
    end
  end

  defp mark_applied(suggestion) do
    update_status(suggestion, :applied,
      applied_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
  end

  defp mark_failed(suggestion, error),
    do: update_status(suggestion, :failed, error: inspect(error))

  defp update_status(suggestion, status, extra \\ []) do
    suggestion
    |> RenameSuggestion.changeset(Enum.into(extra, %{status: status}))
    |> Repo.update()
  end
end
