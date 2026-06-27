defmodule Beatgrid.Library.GenreFolders do
  @moduledoc """
  Context for the genre folders tracks are organized into — the six user-defined
  folders plus their classification rubric. Reference data, seeded at setup.
  """
  import Ecto.Query

  alias Beatgrid.Library.{GenreFolder, GenreFolderQuery, Track}
  alias Beatgrid.Organization
  alias Beatgrid.Repo

  defdelegate list, to: GenreFolderQuery
  defdelegate get_by_key(key), to: GenreFolderQuery

  @doc "Inserts a new folder. A duplicate `:key` returns a changeset error."
  @spec create(map()) :: {:ok, GenreFolder.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %GenreFolder{} |> GenreFolder.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Deletes a folder, unless it's `in_use?/1` (a track or a pending move suggestion
  still references its key) — in which case `{:error, :in_use}`.
  """
  @spec delete(GenreFolder.t()) :: {:ok, GenreFolder.t()} | {:error, :in_use}
  def delete(%GenreFolder{} = folder) do
    if in_use?(folder), do: {:error, :in_use}, else: Repo.delete(folder)
  end

  @doc """
  True if any track currently sits in the folder, or any pending move suggestion
  targets it — i.e. deleting it would orphan references.
  """
  @spec in_use?(GenreFolder.t() | String.t()) :: boolean()
  def in_use?(%GenreFolder{key: key}), do: in_use?(key)

  def in_use?(key) when is_binary(key) do
    has_track?(key) or Organization.pending_to_folder?(key)
  end

  defp has_track?(key) do
    Repo.exists?(from t in Track, where: t.genre_folder == ^key)
  end

  @doc """
  Inserts a folder, or updates the existing one with the same `:key`.
  Idempotent — safe to call from seeds on every boot.
  """
  @spec upsert(map()) :: {:ok, GenreFolder.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    key = attrs[:key] || attrs["key"]

    (GenreFolderQuery.get_by_key(key) || %GenreFolder{})
    |> GenreFolder.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Updates an existing folder (e.g. its classification description)."
  @spec update(GenreFolder.t(), map()) :: {:ok, GenreFolder.t()} | {:error, Ecto.Changeset.t()}
  def update(%GenreFolder{} = folder, attrs) do
    folder |> GenreFolder.changeset(attrs) |> Repo.update()
  end
end
