defmodule Beatgrid.Library.GenreFolderQuery do
  @moduledoc "All reads for `Beatgrid.Library.GenreFolder`."

  import Ecto.Query

  alias Beatgrid.Library.GenreFolder
  alias Beatgrid.Repo

  @spec list() :: [GenreFolder.t()]
  def list do
    GenreFolder
    |> order_by([g], asc: g.sort_order, asc: g.display_name)
    |> Repo.all()
  end

  @spec get_by_key(String.t()) :: GenreFolder.t() | nil
  def get_by_key(key), do: Repo.get_by(GenreFolder, key: key)
end
