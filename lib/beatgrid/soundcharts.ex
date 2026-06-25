defmodule Beatgrid.Soundcharts do
  @moduledoc """
  Enriches tracks with Soundcharts metadata (BPM, key/Camelot, energy…).

  The free tier is a scarce ~1,000 requests, so every call goes through a budget
  guard and is logged to `api_calls`; every fetched song is cached in
  `soundcharts_songs` and never re-fetched. Resolution is idempotent: a track
  already linked to a song makes no API calls.
  """
  import Ecto.Query

  alias Beatgrid.Library.{Normalize, Track, Tracks}
  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.{ApiCall, Camelot, Response, Song, SongQuery}

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Soundcharts.Client, :adapter],
             Beatgrid.Soundcharts.Http
           )

  # A file shorter than this fraction of the cloud duration is a truncated download.
  @truncation_ratio 0.8

  @doc """
  Current request budget. `remaining` is the floor of our own successful-call
  count against the cap and the latest `x-quota-remaining` header — whichever is
  more conservative, so a misbehaving header can never let us overspend.
  """
  @spec budget() :: %{
          cap: integer(),
          used: non_neg_integer(),
          header_remaining: integer() | nil,
          remaining: integer()
        }
  def budget do
    cap = config(:request_cap, 1000)
    used = Repo.aggregate(from(c in ApiCall, where: c.success == true), :count, :id)
    header = latest_quota()
    base = cap - used
    remaining = if is_integer(header), do: min(base, header), else: base
    %{cap: cap, used: used, header_remaining: header, remaining: remaining}
  end

  @doc "Number of cached songs."
  @spec song_count() :: non_neg_integer()
  def song_count, do: SongQuery.count()

  @doc """
  Resolves one track against Soundcharts: search → match by artist → fetch
  metadata → cache the song → link the track. Idempotent and budget-guarded.
  """
  @spec resolve_track(Track.t()) ::
          {:ok, Song.t()} | {:ok, :already_linked} | {:error, atom()}
  def resolve_track(%Track{soundcharts_song_id: id}) when not is_nil(id),
    do: {:ok, :already_linked}

  def resolve_track(%Track{} = track) do
    with :ok <- check_budget(),
         {:ok, items} <- search(track),
         {:ok, {match, confidence}} <- pick_match(items, track),
         :ok <- check_budget(),
         {:ok, attrs} <- fetch_song(match.uuid),
         {:ok, song} <- cache_song(attrs),
         {:ok, _track} <-
           Tracks.update(track, %{
             soundcharts_song_id: song.id,
             sc_match_confidence: confidence,
             quality_issues: quality_issues(track, song)
           }) do
      {:ok, song}
    end
  end

  @doc """
  Resolves up to `limit` unresolved tracks, stopping early if the budget floor
  is reached. Returns a summary map.
  """
  @spec resolve_unresolved(pos_integer()) :: %{
          resolved: non_neg_integer(),
          no_match: non_neg_integer(),
          errors: non_neg_integer(),
          stopped: boolean()
        }
  def resolve_unresolved(limit \\ 50) do
    [status: :present, resolved: false]
    |> Tracks.list_by()
    |> Enum.take(limit)
    |> Enum.reduce_while(%{resolved: 0, no_match: 0, errors: 0, stopped: false}, fn track, acc ->
      case resolve_track(track) do
        {:ok, _} -> {:cont, Map.update!(acc, :resolved, &(&1 + 1))}
        {:error, :budget_exhausted} -> {:halt, %{acc | stopped: true}}
        {:error, :no_match} -> {:cont, Map.update!(acc, :no_match, &(&1 + 1))}
        {:error, _other} -> {:cont, Map.update!(acc, :errors, &(&1 + 1))}
      end
    end)
  end

  # --- internals ---

  defp check_budget do
    if budget().remaining > config(:budget_floor, 50), do: :ok, else: {:error, :budget_exhausted}
  end

  defp search(track) do
    term = search_term(track)
    call("song/search", %{term: term}, fn -> @adapter.search_song(term) end)
  end

  defp fetch_song(uuid) do
    with {:ok, attrs} <- call("song/get", %{uuid: uuid}, fn -> @adapter.get_song(uuid) end) do
      {:ok, Map.put(attrs, :camelot, Camelot.from_key(attrs[:music_key], attrs[:music_mode]))}
    end
  end

  defp call(endpoint, params, fun) do
    occurred_at = DateTime.truncate(DateTime.utc_now(), :second)

    case fun.() do
      {:ok, %Response{} = r} ->
        log_call(endpoint, params, r.status, r.quota_remaining, true, nil, occurred_at)
        {:ok, r.data}

      {:error, reason} ->
        log_call(endpoint, params, nil, nil, false, %{reason: inspect(reason)}, occurred_at)
        {:error, reason}
    end
  end

  defp log_call(endpoint, params, status, quota, success?, error, occurred_at) do
    %ApiCall{}
    |> ApiCall.changeset(%{
      provider: "soundcharts",
      endpoint: endpoint,
      method: "GET",
      request_params: params,
      http_status: status,
      quota_remaining: quota,
      success: success?,
      error: error,
      occurred_at: occurred_at
    })
    |> Repo.insert!()
  end

  defp pick_match([], _track), do: {:error, :no_match}

  defp pick_match(items, track) do
    artist_known? = track.norm_artist not in [nil, ""]
    title_known? = track.norm_title not in [nil, ""]

    scored =
      Enum.map(items, fn item ->
        artist? = artist_known? and Normalize.normalize(item.credit_name) == track.norm_artist
        title? = title_known? and Normalize.normalize(item.name) == track.norm_title
        {item, artist?, title?}
      end)

    {:ok, best_match(scored, artist_known?, hd(items))}
  end

  # Prefer artist+title (high), then artist-only (medium), then — only when the
  # file has no artist tag — title-only (medium). Else the top hit, low confidence.
  defp best_match(scored, artist_known?, fallback) do
    high = Enum.find(scored, fn {_item, artist?, title?} -> artist? and title? end)
    artist = Enum.find(scored, fn {_item, artist?, _title?} -> artist? end)
    title = Enum.find(scored, fn {_item, _artist?, title?} -> title? end)

    cond do
      high -> {elem(high, 0), :high}
      artist -> {elem(artist, 0), :medium}
      title && not artist_known? -> {elem(title, 0), :medium}
      true -> {fallback, :low}
    end
  end

  defp quality_issues(track, song) do
    issues = track.quality_issues || []
    if truncated?(track, song), do: Enum.uniq([:truncated | issues]), else: issues
  end

  defp truncated?(%{duration_ms: ms}, %{duration_seconds: secs})
       when is_integer(ms) and is_integer(secs) and secs > 0,
       do: ms / 1000 < secs * @truncation_ratio

  defp truncated?(_track, _song), do: false

  defp cache_song(attrs) do
    attrs = Map.put(attrs, :fetched_at, DateTime.truncate(DateTime.utc_now(), :second))

    (SongQuery.get_by_sc_uuid(attrs.sc_uuid) || %Song{})
    |> Song.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp search_term(%Track{tag_title: title}) when is_binary(title) and title != "", do: title
  defp search_term(%Track{filename: filename}), do: Path.rootname(filename)

  defp latest_quota do
    from(c in ApiCall,
      where: not is_nil(c.quota_remaining),
      order_by: [desc: c.occurred_at, desc: c.inserted_at],
      limit: 1,
      select: c.quota_remaining
    )
    |> Repo.one()
  end

  defp config(key, default) do
    :beatgrid |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
