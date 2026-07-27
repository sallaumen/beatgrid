defmodule Beatgrid.Dedup.DedupQuery do
  @moduledoc "All reads for duplicate groups."

  import Ecto.Query

  alias Beatgrid.Dedup.DuplicateGroup
  alias Beatgrid.Repo

  @doc "Every group with `members: :track` preloaded — the review cards need the full tree."
  @spec list_groups() :: [DuplicateGroup.t()]
  def list_groups do
    DuplicateGroup
    |> order_by([g], asc: g.match_type, asc: g.signature)
    |> preload(members: :track)
    |> Repo.all()
  end

  @doc """
  Pending groups with the full review tree preloaded (members → track → song,
  plus the keeper). Callers that only need counts should use `count_groups/0`
  instead of paying for these preloads.
  """
  @spec list_pending() :: [DuplicateGroup.t()]
  def list_pending do
    DuplicateGroup
    |> where([g], g.status == :pending)
    |> order_by([g], asc: g.inserted_at)
    |> preload(members: [track: :soundcharts_song], keeper_track: [])
    |> Repo.all()
  end

  @doc "One group with the full review tree preloaded (same shape as `list_pending/0`)."
  @spec get(Ecto.UUID.t()) :: DuplicateGroup.t() | nil
  def get(id) do
    DuplicateGroup
    |> preload(members: [track: :soundcharts_song], keeper_track: [])
    |> Repo.get(id)
  end

  @spec count_groups() :: non_neg_integer()
  def count_groups, do: Repo.aggregate(DuplicateGroup, :count, :id)

  @doc "Ids of pending groups — the slice a re-detect rebuilds (decisions are kept)."
  @spec pending_ids() :: [Ecto.UUID.t()]
  def pending_ids do
    DuplicateGroup
    |> where([g], g.status == :pending)
    |> select([g], g.id)
    |> Repo.all()
  end

  @doc """
  Past decisions: `{match_type, signature}` => the member track-id sets of every
  resolved group under that key (one per time the user decided it).
  """
  @spec resolved_member_index() :: %{{atom(), String.t()} => [MapSet.t()]}
  def resolved_member_index do
    DuplicateGroup
    |> where([g], g.status == :resolved)
    |> preload(:members)
    |> Repo.all()
    |> Enum.group_by(
      fn group -> {group.match_type, group.signature} end,
      fn group -> MapSet.new(group.members, & &1.track_id) end
    )
  end
end
