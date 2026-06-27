defmodule Beatgrid.Dedup.DedupQuery do
  @moduledoc "All reads for duplicate groups."

  import Ecto.Query

  alias Beatgrid.Dedup.DuplicateGroup
  alias Beatgrid.Repo

  @spec list_groups() :: [DuplicateGroup.t()]
  def list_groups do
    DuplicateGroup
    |> order_by([g], asc: g.match_type, asc: g.signature)
    |> preload(members: :track)
    |> Repo.all()
  end

  @spec list_pending() :: [DuplicateGroup.t()]
  def list_pending do
    DuplicateGroup
    |> where([g], g.status == :pending)
    |> order_by([g], asc: g.inserted_at)
    |> preload(members: [track: :soundcharts_song], keeper_track: [])
    |> Repo.all()
  end

  @spec get(Ecto.UUID.t()) :: DuplicateGroup.t() | nil
  def get(id) do
    DuplicateGroup
    |> preload(members: [track: :soundcharts_song], keeper_track: [])
    |> Repo.get(id)
  end

  @spec count_groups() :: non_neg_integer()
  def count_groups, do: Repo.aggregate(DuplicateGroup, :count, :id)
end
