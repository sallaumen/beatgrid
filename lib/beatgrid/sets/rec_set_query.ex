defmodule Beatgrid.Sets.RecSetQuery do
  @moduledoc "All reads for `Beatgrid.Sets.RecSet` and its ordered tracks."

  import Ecto.Query

  alias Beatgrid.Library.Track
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

  @doc "The opener, with the same song preload as the whole queue."
  @spec first_track(Ecto.UUID.t()) :: Beatgrid.Library.Track.t() | nil
  def first_track(set_id), do: Repo.one(ordered_candidate(set_id))

  @doc "The first member following the current track, including across gaps in stored positions."
  @spec next_track(Ecto.UUID.t(), Ecto.UUID.t()) :: Beatgrid.Library.Track.t() | nil
  def next_track(set_id, track_id) do
    case Ecto.UUID.cast(track_id) do
      :error ->
        nil

      {:ok, uuid} ->
        ordered_candidate(set_id)
        |> join(:inner, [seat: st], current in SetTrack,
          on:
            current.rec_set_id == st.rec_set_id and current.track_id == ^uuid and
              current.position < st.position
        )
        |> Repo.one()
    end
  end

  defp ordered_candidate(set_id) do
    from(track in Track,
      join: st in SetTrack,
      as: :seat,
      on: st.track_id == track.id,
      left_join: song in assoc(track, :soundcharts_song),
      where: st.rec_set_id == ^set_id,
      order_by: st.position,
      limit: 1,
      select: track,
      preload: [soundcharts_song: song]
    )
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
    |> Enum.with_index(1)
    |> Enum.map(fn {row, ordinal} ->
      %{track: row.track, role: row.role, position: ordinal, transition: row.transition}
    end)
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
    ids = for id <- set_ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid

    SetTrack
    |> where([st], st.rec_set_id in ^ids)
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

  @doc "Sets holding seats that point at non-present tracks: `%{rec_set_id => count}`."
  @spec broken_seat_counts() :: %{Ecto.UUID.t() => non_neg_integer()}
  def broken_seat_counts do
    SetTrack
    |> join(:inner, [st], t in assoc(st, :track))
    |> where([_st, t], t.status != :present)
    |> group_by([st], st.rec_set_id)
    |> select([st], {st.rec_set_id, count()})
    |> Repo.all()
    |> Map.new()
  end
end
