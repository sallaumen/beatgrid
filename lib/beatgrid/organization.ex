defmodule Beatgrid.Organization do
  @moduledoc """
  The suggest → confirm → apply → undo workflow. Move suggestions are proposed
  (by rule, dedup, AI, or manually) and only touch disk when applied; applied
  moves are reversible.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{GenreFolders, Track, Tracks}
  alias Beatgrid.Organization.{MoveSuggestion, MoveSuggestionQuery}
  alias Beatgrid.Repo

  def list_by(opts \\ []), do: MoveSuggestionQuery.list_by(opts)
  def count(opts \\ []), do: MoveSuggestionQuery.count(opts)

  @spec get(Ecto.UUID.t()) :: MoveSuggestion.t() | nil
  def get(id), do: Repo.get(MoveSuggestion, id)

  @spec create_suggestion(map()) :: {:ok, MoveSuggestion.t()} | {:error, Ecto.Changeset.t()}
  def create_suggestion(attrs) do
    %MoveSuggestion{} |> MoveSuggestion.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Creates a pending `:rule` suggestion for each inbox track (genre_folder nil)
  whose `source_playlist` matches a rule (`playlist name => genre key`). Skips
  tracks that already have a pending suggestion. Returns the batch id and count.
  """
  @spec suggest_by_rule(map()) :: {:ok, %{batch_id: Ecto.UUID.t(), created: non_neg_integer()}}
  def suggest_by_rule(rules \\ playlist_rules()) do
    batch_id = Uniq.UUID.uuid7()
    already = MapSet.new(MoveSuggestionQuery.list_by(status: :pending), & &1.track_id)

    created =
      [status: :present, genre_folder: nil]
      |> Tracks.list_by()
      |> Enum.reject(&MapSet.member?(already, &1.id))
      |> Enum.reduce(0, fn track, count ->
        case Map.get(rules, track.source_playlist) do
          nil ->
            count

          genre_key ->
            create_rule_suggestion(track, genre_key, batch_id)
            count + 1
        end
      end)

    {:ok, %{batch_id: batch_id, created: created}}
  end

  @doc """
  Applies each suggestion: moves the track's file into the target genre folder and
  records the outcome on the suggestion. One failure doesn't abort the batch.
  """
  @spec apply_batch([MoveSuggestion.t()]) ::
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
  @spec set_status(MoveSuggestion.t(), atom()) ::
          {:ok, MoveSuggestion.t()} | {:error, Ecto.Changeset.t()}
  def set_status(suggestion, status), do: update_status(suggestion, status)

  @doc "Edits the target genre folder and marks the suggestion approved."
  @spec edit_to(MoveSuggestion.t(), String.t()) ::
          {:ok, MoveSuggestion.t()} | {:error, Ecto.Changeset.t()}
  def edit_to(suggestion, to_genre_folder) do
    suggestion
    |> MoveSuggestion.changeset(%{to_genre_folder: to_genre_folder, status: :approved})
    |> Repo.update()
  end

  @doc "Reverses an applied move, returning the track to its original location."
  @spec undo(MoveSuggestion.t()) :: {:ok, MoveSuggestion.t()} | {:error, term()}
  def undo(%MoveSuggestion{status: :applied} = suggestion) do
    with %Track{} = track <- Tracks.get(suggestion.track_id),
         genre_folder = Library.genre_folder_for_rel(suggestion.from_rel_path),
         {:ok, _moved} <- Library.relocate(track, suggestion.from_rel_path, genre_folder) do
      update_status(suggestion, :undone)
    end
  end

  def undo(%MoveSuggestion{}), do: {:error, :not_applied}

  defp apply_one(suggestion) do
    with %Track{} = track <- Tracks.get(suggestion.track_id),
         {:ok, dir} <- dir_name_for(suggestion.to_genre_folder),
         dest_rel = Path.join(dir, track.filename),
         {:ok, _moved} <- Library.relocate(track, dest_rel, suggestion.to_genre_folder) do
      mark_applied(suggestion)
      :applied
    else
      error ->
        mark_failed(suggestion, error)
        :failed
    end
  end

  defp dir_name_for(key) do
    case GenreFolders.get_by_key(key) do
      nil -> {:error, {:unknown_genre_folder, key}}
      folder -> {:ok, folder.dir_name}
    end
  end

  defp mark_applied(suggestion) do
    update_status(suggestion, :applied,
      applied_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
  end

  defp mark_failed(suggestion, error) do
    update_status(suggestion, :failed, error: inspect(error))
  end

  defp update_status(suggestion, status, extra \\ []) do
    suggestion
    |> MoveSuggestion.changeset(Enum.into(extra, %{status: status}))
    |> Repo.update()
  end

  defp create_rule_suggestion(track, genre_key, batch_id) do
    {:ok, _suggestion} =
      create_suggestion(%{
        track_id: track.id,
        from_rel_path: track.rel_path,
        to_genre_folder: genre_key,
        source: :rule,
        confidence: 0.9,
        reason: "source playlist #{track.source_playlist} → #{genre_key}",
        batch_id: batch_id
      })
  end

  defp playlist_rules, do: Application.get_env(:beatgrid, :playlist_genre_rules, %{})
end
