defmodule Beatgrid.Repertoire do
  @moduledoc """
  Read-only analytics over the library — the numbers behind the dashboard.
  Counts, distributions and histograms; no mutations, no AI.
  """
  import Ecto.Query

  alias Beatgrid.Library.Track
  alias Beatgrid.Repo

  @doc "Headline dashboard counts."
  @spec overview() :: %{
          total: non_neg_integer(),
          resolved: non_neg_integer(),
          unresolved: non_neg_integer(),
          truncated: non_neg_integer(),
          by_confidence: %{atom() => non_neg_integer()}
        }
  def overview do
    %{
      total: count(present()),
      resolved: count(where(present(), [t], not is_nil(t.soundcharts_song_id))),
      unresolved: count(where(present(), [t], is_nil(t.soundcharts_song_id))),
      truncated: count(where(present(), [t], fragment("? = ANY(quality_issues)", "truncated"))),
      by_confidence: by_confidence()
    }
  end

  @doc "Present-track counts per genre folder."
  @spec genre_distribution() :: %{String.t() => non_neg_integer()}
  def genre_distribution do
    present()
    |> where([t], not is_nil(t.genre_folder))
    |> group_by([t], t.genre_folder)
    |> select([t], {t.genre_folder, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Top artists by present-track count."
  @spec top_artists(pos_integer()) :: [{String.t(), non_neg_integer()}]
  def top_artists(limit \\ 20) do
    present()
    |> where([t], not is_nil(t.tag_artist))
    |> group_by([t], t.tag_artist)
    |> select([t], {t.tag_artist, count(t.id)})
    |> order_by([t], desc: count(t.id))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Resolved-track counts bucketed by BPM (default bucket 5)."
  @spec bpm_histogram(pos_integer()) :: %{integer() => non_neg_integer()}
  def bpm_histogram(bucket \\ 5) do
    Track
    |> join(:inner, [t], s in assoc(t, :soundcharts_song))
    |> where([t, s], not is_nil(s.tempo_bpm))
    |> select(
      [t, s],
      {selected_as(fragment("(floor(? / ?) * ?)::int", s.tempo_bpm, ^bucket, ^bucket), :bucket),
       count(t.id)}
    )
    |> group_by([t, s], selected_as(:bucket))
    |> Repo.all()
    |> Map.new()
  end

  @doc "Resolved-track counts bucketed by release decade."
  @spec decade_distribution() :: %{integer() => non_neg_integer()}
  def decade_distribution do
    Track
    |> join(:inner, [t], s in assoc(t, :soundcharts_song))
    |> where([t, s], not is_nil(s.release_date))
    |> select(
      [t, s],
      {selected_as(
         fragment("((extract(year from ?)::int / 10) * 10)::int", s.release_date),
         :decade
       ), count(t.id)}
    )
    |> group_by([t, s], selected_as(:decade))
    |> Repo.all()
    |> Map.new()
  end

  defp present, do: from(t in Track, where: t.status == :present)
  defp count(query), do: Repo.aggregate(query, :count, :id)

  defp by_confidence do
    present()
    |> where([t], not is_nil(t.sc_match_confidence))
    |> group_by([t], t.sc_match_confidence)
    |> select([t], {t.sc_match_confidence, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end
end
