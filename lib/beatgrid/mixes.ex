defmodule Beatgrid.Mixes do
  @moduledoc """
  Online DJ sets ("mixes") imported for study: a `Mix` (the recorded set) and its
  ordered `Segment`s (the tracks within it). This module is the data/query boundary;
  download, audio analysis, and AI naming live in their own ports/workers.
  """
  import Ecto.Query

  alias Beatgrid.Library.{Normalize, Track}
  alias Beatgrid.Mixes.{Mix, Segment}
  alias Beatgrid.Repo

  @spec create_mix(map()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def create_mix(attrs), do: %Mix{} |> Mix.changeset(attrs) |> Repo.insert()

  @spec get_mix(binary()) :: Mix.t() | nil
  def get_mix(id), do: Repo.get(Mix, id)

  @spec get_with_segments(binary()) :: Mix.t() | nil
  def get_with_segments(id) do
    Mix
    |> Repo.get(id)
    |> Repo.preload(segments: from(s in Segment, order_by: [asc: s.position]))
  end

  @spec list_mixes() :: [Mix.t()]
  def list_mixes, do: Repo.all(from m in Mix, order_by: [desc: m.inserted_at])

  @spec create_segment(map()) :: {:ok, Segment.t()} | {:error, Ecto.Changeset.t()}
  def create_segment(attrs), do: %Segment{} |> Segment.changeset(attrs) |> Repo.insert()

  @spec update_segment(Segment.t(), map()) :: {:ok, Segment.t()} | {:error, Ecto.Changeset.t()}
  def update_segment(%Segment{} = segment, attrs),
    do: segment |> Segment.changeset(attrs) |> Repo.update()

  @spec match_track(String.t() | nil, String.t() | nil) ::
          %{track_id: binary(), confidence: :high} | nil
  def match_track(artist, title) do
    na = Normalize.normalize(artist)
    nt = Normalize.normalize(title)

    if na != "" and nt != "" do
      Track
      |> where([t], t.status == :present and t.norm_artist == ^na and t.norm_title == ^nt)
      |> order_by([t], asc: t.inserted_at)
      |> limit(1)
      |> Repo.one()
      |> case do
        nil -> nil
        track -> %{track_id: track.id, confidence: :high}
      end
    end
  end
end
