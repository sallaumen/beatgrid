defmodule Beatgrid.Workers.RecommendWorker do
  @moduledoc """
  Generates AI song recommendations and PERSISTS them (deduped) so the history survives —
  folder gaps (`scope: "folder"`) or per-track matches (`scope: "track"`). Quota-free (claude
  only). Broadcasts `{:recommend_progress, …}` so the LiveView reloads. Queue `:ai`.
  """
  use Oban.Worker, queue: :ai, max_attempts: 2

  alias Beatgrid.Library.{GenreFolders, Tracks}
  alias Beatgrid.Repertoire
  alias Beatgrid.Repertoire.RecommendationAI

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "folder", "folder" => key, "batch_id" => bid}}) do
    case GenreFolders.get_by_key(key) do
      nil ->
        {:cancel, :unknown_folder}

      _folder ->
        run(bid, "folder", key, fn -> RecommendationAI.suggest_gaps(key) end, %{
          genre_folder: key,
          source: :gaps
        })
    end
  end

  def perform(%Oban.Job{args: %{"scope" => "track", "track_id" => id, "batch_id" => bid}}) do
    case Tracks.get(id) do
      nil ->
        {:cancel, :track_not_found}

      track ->
        run(bid, "track", id, fn -> RecommendationAI.suggest_matches(track) end, %{
          track_id: id,
          genre_folder: track.genre_folder,
          source: :match
        })
    end
  end

  defp run(bid, scope, key, ai_fun, attrs) do
    Repertoire.broadcast_recommend(%{
      batch_id: bid,
      scope: scope,
      key: key,
      status: :running,
      count: 0
    })

    case ai_fun.() do
      {:ok, gaps} ->
        inserted = Enum.count(gaps, &persist(&1, attrs))

        Repertoire.broadcast_recommend(%{
          batch_id: bid,
          scope: scope,
          key: key,
          status: :done,
          count: inserted
        })

        :ok

      {:error, reason} ->
        Repertoire.broadcast_recommend(%{
          batch_id: bid,
          scope: scope,
          key: key,
          status: :error,
          count: 0
        })

        {:error, reason}
    end
  end

  defp persist(%{artist: a, song: s, reason: r}, attrs) do
    if duplicate?(attrs, a, s) do
      false
    else
      {:ok, _} =
        attrs
        |> Map.merge(%{artist: a, song: s, reason: r, youtube_query: "#{a} #{s}"})
        |> Repertoire.create_recommendation()

      true
    end
  end

  defp duplicate?(%{source: :gaps, genre_folder: k}, a, s),
    do:
      Repertoire.count_recommendations(
        genre_folder: k,
        source: :gaps,
        artist: a,
        song: s,
        statuses: [:new, :imported]
      ) > 0

  defp duplicate?(%{source: :match, track_id: id}, a, s),
    do:
      Repertoire.count_recommendations(
        track_id: id,
        source: :match,
        artist: a,
        song: s,
        statuses: [:new, :imported]
      ) > 0
end
