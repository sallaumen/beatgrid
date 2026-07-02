defmodule Beatgrid.Mixes.MixQuery do
  @moduledoc "All reads for `Beatgrid.Mixes` — mixes, segments and DJ parts."

  import Ecto.Query

  alias Beatgrid.Mixes.{DjPart, Mix, Segment}
  alias Beatgrid.Repo

  @spec get(binary()) :: Mix.t() | nil
  def get(id), do: Repo.get(Mix, id)

  @spec get_with_segments(binary()) :: Mix.t() | nil
  def get_with_segments(id) do
    Mix |> Repo.get(id) |> Repo.preload(segments: segments_by_position())
  end

  @spec get_with_dj_parts(binary()) :: Mix.t() | nil
  def get_with_dj_parts(id) do
    Mix
    |> Repo.get(id)
    |> Repo.preload(
      segments: segments_by_position(),
      dj_parts: from(p in DjPart, order_by: [asc: p.position])
    )
  end

  @spec list() :: [Mix.t()]
  def list do
    Repo.all(from m in Mix, order_by: [desc: m.inserted_at], preload: [:segments])
  end

  @spec get_segment_with_mix(binary()) :: Segment.t() | nil
  def get_segment_with_mix(id), do: Segment |> Repo.get(id) |> Repo.preload(:mix)

  @doc "A mix's segments ordered by their start time (the DJ-part snapping input)."
  @spec segments_by_start(binary()) :: [Segment.t()]
  def segments_by_start(mix_id),
    do: Repo.all(from s in Segment, where: s.mix_id == ^mix_id, order_by: [asc: s.start_ms])

  @spec get_dj_part(binary()) :: DjPart.t() | nil
  def get_dj_part(id), do: Repo.get(DjPart, id)

  @spec manual_dj_parts?(binary()) :: boolean()
  def manual_dj_parts?(mix_id),
    do: Repo.exists?(from p in DjPart, where: p.mix_id == ^mix_id and p.source == :manual)

  defp segments_by_position, do: from(s in Segment, order_by: [asc: s.position])
end
