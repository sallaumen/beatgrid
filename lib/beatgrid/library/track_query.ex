defmodule Beatgrid.Library.TrackQuery do
  @moduledoc "All reads for `Beatgrid.Library.Track`."

  import Ecto.Query

  alias Beatgrid.Library.Track
  alias Beatgrid.Repo

  @type list_opt ::
          {:status, atom()}
          | {:genre_folder, String.t() | nil}
          | {:with_quality_issues, boolean()}
          | {:resolved, boolean()}
          | {:analyzed, boolean()}
          | {:order_by, term()}

  @spec list_by([list_opt()]) :: [Track.t()]
  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, asc: :rel_path)
    |> Enum.reduce(Track, &reduce_opt/2)
    |> Repo.all()
  end

  @spec get(Ecto.UUID.t()) :: Track.t() | nil
  def get(id), do: Repo.get(Track, id)

  @spec get_with_song(Ecto.UUID.t()) :: Track.t() | nil
  def get_with_song(id) do
    case Repo.get(Track, id) do
      nil -> nil
      track -> Repo.preload(track, :soundcharts_song)
    end
  end

  @spec get_by_path(String.t()) :: Track.t() | nil
  def get_by_path(rel_path), do: Repo.get_by(Track, rel_path: rel_path)

  @doc """
  Library browse query: present tracks with the song preloaded, filtered by a map
  of optional filters (`genre_folder`, `rating_min`, `confidence`, `tag`,
  `bpm_min`, `bpm_max`, `search`). Used by the Biblioteca screen.
  """
  @spec library(map()) :: [Track.t()]
  def library(filters \\ %{}) do
    Track
    |> join(:left, [t], s in assoc(t, :soundcharts_song), as: :song)
    |> where([t], t.status == :present)
    |> filter(:genre_folder, filters)
    |> filter(:rating_min, filters)
    |> filter(:confidence, filters)
    |> filter(:tag, filters)
    |> filter(:bpm_min, filters)
    |> filter(:bpm_max, filters)
    |> filter(:search, filters)
    |> order_by([t], asc: t.norm_artist, asc: t.norm_title)
    |> preload([song: s], soundcharts_song: s)
    |> Repo.all()
  end

  defp filter(query, key, filters) do
    case Map.get(filters, key) || Map.get(filters, to_string(key)) do
      nil -> query
      "" -> query
      value -> apply_filter(query, key, value)
    end
  end

  defp apply_filter(q, :genre_folder, v), do: where(q, [t], t.genre_folder == ^v)
  defp apply_filter(q, :rating_min, v), do: where(q, [t], t.rating >= ^to_int(v))
  defp apply_filter(q, :confidence, v), do: where(q, [t], t.sc_match_confidence == ^to_atom(v))
  defp apply_filter(q, :tag, v), do: where(q, [t], fragment("? = ANY(?)", ^v, t.tags))
  defp apply_filter(q, :bpm_min, v), do: where(q, [song: s], s.tempo_bpm >= ^to_num(v))
  defp apply_filter(q, :bpm_max, v), do: where(q, [song: s], s.tempo_bpm <= ^to_num(v))

  defp apply_filter(q, :search, v) do
    like = "%#{v}%"
    where(q, [t], ilike(t.norm_artist, ^like) or ilike(t.norm_title, ^like))
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_num(v) when is_number(v), do: v
  defp to_num(v) when is_binary(v), do: String.to_integer(v)
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_existing_atom(v)

  @spec count([list_opt()]) :: non_neg_integer()
  def count(opts \\ []) do
    opts
    |> Enum.reduce(Track, &reduce_opt/2)
    |> Repo.aggregate(:count, :id)
  end

  defp reduce_opt({:status, status}, q), do: where(q, [t], t.status == ^status)
  defp reduce_opt({:genre_folder, nil}, q), do: where(q, [t], is_nil(t.genre_folder))
  defp reduce_opt({:genre_folder, folder}, q), do: where(q, [t], t.genre_folder == ^folder)
  defp reduce_opt({:with_quality_issues, true}, q), do: where(q, [t], t.quality_issues != ^[])
  defp reduce_opt({:with_quality_issues, false}, q), do: where(q, [t], t.quality_issues == ^[])
  defp reduce_opt({:resolved, true}, q), do: where(q, [t], not is_nil(t.soundcharts_song_id))
  defp reduce_opt({:resolved, false}, q), do: where(q, [t], is_nil(t.soundcharts_song_id))
  defp reduce_opt({:analyzed, true}, q), do: where(q, [t], not is_nil(t.analyzed_at))
  defp reduce_opt({:analyzed, false}, q), do: where(q, [t], is_nil(t.analyzed_at))
  defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)
end
