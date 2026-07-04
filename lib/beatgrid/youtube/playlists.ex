defmodule Beatgrid.YouTube.Playlists do
  @moduledoc """
  Views YouTube-imported tracks as the playlists they came from, and turns a
  playlist into a ready-to-play set.

  Playlists are not a stored entity — a track carries its origin in `raw_tags`
  (`youtube_playlist_url`, and, for imports done after this feature landed,
  `youtube_playlist_index` and `youtube_playlist_title`). `group/1` derives the
  playlists from a loaded track list; `create_set/1` builds a `RecSet` from one,
  in order, and hands the transition mixing to the existing `Sets` engine.
  """
  alias Beatgrid.Sets

  @fallback_title "Playlist do YouTube"

  @type playlist :: %{
          key: String.t(),
          url: String.t(),
          title: String.t(),
          tracks: [Beatgrid.Library.Track.t()],
          count: non_neg_integer()
        }

  @doc """
  Splits a loaded track list into `%{playlists: [...], singles: [...]}`. Tracks
  sharing a `youtube_playlist_url` form a playlist (newest playlist first); tracks
  with none stay as `singles` (input order preserved). Within a playlist, tracks
  are ordered by `youtube_playlist_index` when every track has one, else by
  `inserted_at` (best effort for imports predating index capture).
  """
  @spec group([Beatgrid.Library.Track.t()]) :: %{
          playlists: [playlist()],
          singles: [Beatgrid.Library.Track.t()]
        }
  def group(tracks) do
    {in_playlist, singles} = Enum.split_with(tracks, &(playlist_url(&1) != nil))

    playlists =
      in_playlist
      |> Enum.group_by(&playlist_url/1)
      |> Enum.sort_by(fn {_url, ts} -> newest(ts) end, {:desc, DateTime})
      |> Enum.map(fn {url, ts} -> build_playlist(url, ts) end)

    %{playlists: playlists, singles: singles}
  end

  @doc """
  Creates a `RecSet` named after the playlist, appends its tracks in order, and
  auto-connects every consecutive pair with a suggested DJ transition (which the
  player can toggle). Returns `{:ok, set}`.
  """
  @spec create_set(playlist()) :: {:ok, Beatgrid.Sets.RecSet.t()}
  def create_set(%{title: title, tracks: tracks}) do
    {:ok, set} = Sets.create(title)
    Enum.each(tracks, &Sets.append(set, &1))
    Sets.connect_all(set)
    {:ok, set}
  end

  defp build_playlist(url, tracks) do
    %{
      key: url,
      url: url,
      title: title_of(tracks),
      tracks: order_tracks(tracks),
      count: length(tracks)
    }
  end

  defp order_tracks(tracks) do
    if Enum.all?(tracks, &(index_of(&1) != nil)) do
      Enum.sort_by(tracks, &index_of/1)
    else
      Enum.sort_by(tracks, & &1.inserted_at, DateTime)
    end
  end

  defp title_of(tracks) do
    case Enum.find_value(tracks, &blank_to_nil(raw(&1)["youtube_playlist_title"])) do
      nil -> @fallback_title
      title -> title
    end
  end

  defp newest(tracks), do: tracks |> Enum.map(& &1.inserted_at) |> Enum.max(DateTime)

  defp playlist_url(track), do: raw(track)["youtube_playlist_url"]
  defp index_of(track), do: raw(track)["youtube_playlist_index"]
  defp raw(track), do: track.raw_tags || %{}

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v
end
