defmodule Beatgrid.Library do
  @moduledoc """
  The Library context — the librarian over the on-disk music collection.

  The filesystem under `library_root/0` is the source of truth; this context
  reflects and edits it. In Phase 0 it owns library initialization; scanning,
  quality flags, dedup, import, and moves are added in later phases.
  """
  alias Beatgrid.Library.GenreFolders

  @structural_dirs ["_Inbox", "_Quarantine"]

  @doc "The on-disk library root (the source of truth)."
  @spec library_root() :: String.t()
  def library_root, do: Application.fetch_env!(:beatgrid, :library_root)

  @doc """
  Creates the library root and its folders (one per genre folder, plus the
  structural `_Inbox` and `_Quarantine`). Idempotent. Returns the created paths.
  """
  # Note: `root` comes from app config and `dir_name`s from DB-seeded reference data —
  # never external input — so the directory creation below is not a traversal risk.
  @spec init_library(String.t()) :: {:ok, [String.t()]}
  def init_library(root \\ library_root()) do
    dir_names = Enum.map(GenreFolders.list(), & &1.dir_name) ++ @structural_dirs
    paths = Enum.map(dir_names, &Path.join(root, &1))

    File.mkdir_p!(root)
    Enum.each(paths, &File.mkdir_p!/1)

    {:ok, paths}
  end
end
