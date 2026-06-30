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
end
