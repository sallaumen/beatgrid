defmodule Beatgrid.Mixes do
  @moduledoc """
  Online DJ sets ("mixes") imported for study: a `Mix` (the recorded set) and its
  ordered `Segment`s (the tracks within it). This module is the data/query boundary;
  download, audio analysis, and AI naming live in their own ports/workers.
  """
  import Ecto.Query

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
end
