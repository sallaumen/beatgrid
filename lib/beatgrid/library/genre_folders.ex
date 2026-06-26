defmodule Beatgrid.Library.GenreFolders do
  @moduledoc """
  Context for the genre folders tracks are organized into — the six user-defined
  folders plus their classification rubric. Reference data, seeded at setup.
  """
  alias Beatgrid.Library.{GenreFolder, GenreFolderQuery}
  alias Beatgrid.Repo

  defdelegate list, to: GenreFolderQuery
  defdelegate get_by_key(key), to: GenreFolderQuery

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
