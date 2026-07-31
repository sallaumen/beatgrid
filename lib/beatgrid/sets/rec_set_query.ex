defmodule Beatgrid.Sets.RecSetQuery do
  @moduledoc "All reads for `Beatgrid.Sets.RecSet` and its ordered tracks."

  import Ecto.Query

  alias Beatgrid.Repo
  alias Beatgrid.Sets.{RecSet, SetTrack}

  @spec list() :: [RecSet.t()]
  def list, do: Repo.all(from s in RecSet, order_by: [desc: s.inserted_at])

  @spec get(Ecto.UUID.t()) :: RecSet.t() | nil
  def get(id), do: Repo.get(RecSet, id)

  @spec count(Ecto.UUID.t()) :: non_neg_integer()
  def count(set_id) do
    SetTrack |> where([st], st.rec_set_id == ^set_id) |> Repo.aggregate(:count, :id)
  end

  @doc "Highest occupied position (0 for an empty set) — deletions may leave holes, so count is not it."
  @spec max_position(Ecto.UUID.t()) :: non_neg_integer()
  def max_position(set_id) do
    SetTrack
    |> where([st], st.rec_set_id == ^set_id)
    |> Repo.aggregate(:max, :position)
    |> Kernel.||(0)
  end

  @doc "Row-locks the set for the current transaction, serializing concurrent membership writes."
  @spec lock(Ecto.UUID.t()) :: RecSet.t() | nil
  def lock(set_id) do
    RecSet
    |> where([s], s.id == ^set_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc "The set's tracks, in position order, with the soundcharts song preloaded."
  @spec ordered_tracks(Ecto.UUID.t()) :: [Beatgrid.Library.Track.t()]
  def ordered_tracks(set_id) do
    SetTrack
    |> where([st], st.rec_set_id == ^set_id)
    |> order_by([st], asc: st.position)
    |> preload(track: :soundcharts_song)
    |> Repo.all()
    |> Enum.map(& &1.track)
  end

  @doc "The set's entries (track + section role + incoming transition) in position order."
  @spec ordered_entries(Ecto.UUID.t()) :: [
          %{
            track: Beatgrid.Library.Track.t(),
            role: String.t() | nil,
            position: integer(),
            transition: map() | nil
          }
        ]
  def ordered_entries(set_id) do
    SetTrack
    |> where([st], st.rec_set_id == ^set_id)
    |> order_by([st], asc: st.position)
    |> preload(track: :soundcharts_song)
    |> Repo.all()
    |> Enum.map(
      &%{track: &1.track, role: &1.role, position: &1.position, transition: &1.transition}
    )
  end

  @doc "Set-track rows in position order (for reindexing)."
  @spec rows(Ecto.UUID.t()) :: [SetTrack.t()]
  def rows(set_id) do
    SetTrack
    |> where([st], st.rec_set_id == ^set_id)
    |> order_by([st], asc: st.position)
    |> Repo.all()
  end

  @doc "Distinct track ids that appear in ANY of the given sets (cross-set dedup)."
  @spec track_ids_in([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def track_ids_in([]), do: []

  def track_ids_in(set_ids) do
    SetTrack
    |> where([st], st.rec_set_id in ^set_ids)
    |> distinct([st], st.track_id)
    |> select([st], st.track_id)
    |> Repo.all()
  end

  @doc "The membership row of `track_id` in `set_id` — raises if it isn't a member."
  @spec row!(Ecto.UUID.t(), Ecto.UUID.t()) :: SetTrack.t()
  def row!(set_id, track_id),
    do: Repo.get_by!(SetTrack, rec_set_id: set_id, track_id: track_id)

  @doc "The membership row of `track_id` in `set_id`, or an error for a stale reference."
  @spec fetch_row(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, SetTrack.t()} | {:error, :not_a_member}
  def fetch_row(set_id, track_id) do
    case Repo.get_by(SetTrack, rec_set_id: set_id, track_id: track_id) do
      nil -> {:error, :not_a_member}
      row -> {:ok, row}
    end
  end

  @doc "Every membership row pointing at `track_id`, across all sets."
  @spec rows_for_track(Ecto.UUID.t()) :: [SetTrack.t()]
  def rows_for_track(track_id),
    do: SetTrack |> where([st], st.track_id == ^track_id) |> Repo.all()
end
