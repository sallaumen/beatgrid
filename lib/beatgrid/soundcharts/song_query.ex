defmodule Beatgrid.Soundcharts.SongQuery do
  @moduledoc "All reads for `Beatgrid.Soundcharts.Song`."

  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.Song

  @spec get_by_sc_uuid(String.t()) :: Song.t() | nil
  def get_by_sc_uuid(sc_uuid), do: Repo.get_by(Song, sc_uuid: sc_uuid)

  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(Song, :count, :id)
end
