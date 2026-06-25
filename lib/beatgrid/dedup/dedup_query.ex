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

  @spec count_groups() :: non_neg_integer()
  def count_groups, do: Repo.aggregate(DuplicateGroup, :count, :id)
end
