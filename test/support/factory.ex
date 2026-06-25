defmodule Beatgrid.Factory do
  @moduledoc """
  ExMachina factories. Keep defaults minimal — every default cascades into other
  tests. Use the `Map.pop_lazy` optional-association idiom when adding associations.
  """
  use ExMachina.Ecto, repo: Beatgrid.Repo

  alias Beatgrid.Library.GenreFolder

  def genre_folder_factory do
    %GenreFolder{
      key: sequence(:genre_folder_key, &"genre-#{&1}"),
      display_name: sequence(:genre_folder_name, &"Genre #{&1}"),
      dir_name: sequence(:genre_folder_dir, &"Genre #{&1}"),
      sort_order: sequence(:genre_folder_sort, & &1)
    }
  end
end
