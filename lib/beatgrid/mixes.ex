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
  alias Beatgrid.Workers.MixDownloadWorker

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Mixes.Source, :adapter],
             Beatgrid.Mixes.Source.YtDlp
           )
  @topic "mixes"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @spec broadcast(map()) :: :ok
  def broadcast(payload),
    do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:mix_progress, payload})

  @spec import_url(String.t()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def import_url(url) do
    with {:ok, mix} <- create_mix(%{source: "soundcloud", source_url: url, status: :downloading}),
         {:ok, _job} <- Oban.insert(MixDownloadWorker.new(%{mix_id: mix.id})) do
      {:ok, mix}
    end
  end

  @spec fetch_source(String.t(), String.t()) ::
          {:ok, Beatgrid.Mixes.Source.meta()} | {:error, term()}
  def fetch_source(url, dest_dir), do: @adapter.fetch(url, dest_dir)

  @spec update_mix(Mix.t(), map()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def update_mix(%Mix{} = mix, attrs), do: mix |> Mix.changeset(attrs) |> Repo.update()

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

  @spec set_status(Mix.t(), atom(), map()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def set_status(%Mix{} = mix, status, extra \\ %{}),
    do: update_mix(mix, Map.put(extra, :status, status))

  @doc "Replaces all of a mix's segments with the given attrs (in a transaction)."
  @spec replace_segments(Mix.t(), [map()]) :: {:ok, non_neg_integer()}
  def replace_segments(%Mix{id: mix_id}, segments) do
    Repo.transaction(fn ->
      Repo.delete_all(from s in Segment, where: s.mix_id == ^mix_id)

      Enum.each(segments, fn attrs ->
        %Segment{} |> Segment.changeset(Map.put(attrs, :mix_id, mix_id)) |> Repo.insert!()
      end)

      length(segments)
    end)
  end

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
