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

  @cache_key {__MODULE__, :by_key}

  @doc """
  key → folder map for hot per-row reads (the UI badges), cached in ONE
  `:persistent_term` entry: a single select on first read, erased on every
  folder write here. Same contract as `Beatgrid.Settings` — tests that insert
  folders via the factory (bypassing these writes) and read through the cache
  must `invalidate/0` first; the sandbox rolls rows back, the cache is global.
  """
  @spec by_key() :: %{String.t() => GenreFolder.t()}
  def by_key do
    case :persistent_term.get(@cache_key, :miss) do
      :miss ->
        map = Map.new(GenreFolderQuery.list(), &{&1.key, &1})
        :persistent_term.put(@cache_key, map)
        map

      map ->
        map
    end
  end

  @doc "Drops the folder cache; the next `by_key/0` reloads. Every write below calls this."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc "Inserts a new folder. A duplicate `:key` returns a changeset error."
  @spec create(map()) :: {:ok, GenreFolder.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %GenreFolder{} |> GenreFolder.changeset(attrs) |> Repo.insert() |> invalidating()
  end

  @default_color "#9498a6"

  @doc """
  Creates a folder from the user-facing name: trims it, slugs it into the key
  (accents stripped), mirrors it as `dir_name`, and appends the sort order.
  `{:error, :invalid_name}` when the name slugs to nothing.
  """
  @spec create_from_name(String.t(), String.t() | nil) ::
          {:ok, GenreFolder.t()} | {:error, :invalid_name | Ecto.Changeset.t()}
  def create_from_name(display_name, color) do
    name = String.trim(display_name)

    case slugify(name) do
      "" ->
        {:error, :invalid_name}

      key ->
        create(%{
          key: key,
          display_name: name,
          dir_name: name,
          color: color || @default_color,
          description: "",
          sort_order: next_sort_order()
        })
    end
  end

  defp next_sort_order do
    case Repo.aggregate(GenreFolder, :max, :sort_order) do
      nil -> 0
      max -> max + 1
    end
  end

  defp slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  @doc """
  Deletes a folder, unless it's `in_use?/1` (a track or a pending move suggestion
  still references its key) — in which case `{:error, :in_use}`.
  """
  @spec delete(GenreFolder.t()) :: {:ok, GenreFolder.t()} | {:error, :in_use}
  def delete(%GenreFolder{} = folder) do
    if in_use?(folder), do: {:error, :in_use}, else: folder |> Repo.delete() |> invalidating()
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

  @doc """
  Every folder key referenced by a track or a pending move suggestion — the
  whole set in two queries, for screens that flag N folders per render.
  """
  @spec in_use_keys() :: MapSet.t(String.t())
  def in_use_keys do
    track_keys =
      Repo.all(
        from t in Track,
          where: not is_nil(t.genre_folder),
          distinct: true,
          select: t.genre_folder
      )

    MapSet.new(track_keys ++ Organization.pending_to_folder_keys())
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
    |> invalidating()
  end

  @doc "Updates an existing folder (e.g. its classification description)."
  @spec update(GenreFolder.t(), map()) :: {:ok, GenreFolder.t()} | {:error, Ecto.Changeset.t()}
  def update(%GenreFolder{} = folder, attrs) do
    folder |> GenreFolder.changeset(attrs) |> Repo.update() |> invalidating()
  end

  defp invalidating({:ok, _} = result) do
    invalidate()
    result
  end

  defp invalidating(result), do: result
end
