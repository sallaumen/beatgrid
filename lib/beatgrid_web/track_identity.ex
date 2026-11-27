defmodule BeatgridWeb.TrackIdentity do
  @moduledoc "Presentation helpers for distinguishing recordings with the same displayed title and artist."

  alias Beatgrid.Library.Normalize

  @doc "IDs of recordings whose visible title and artist are shared by another distinct ID."
  @spec ambiguous_ids([map()]) :: MapSet.t(String.t())
  def ambiguous_ids(tracks) do
    tracks
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(&display_key/1)
    |> Enum.reduce(MapSet.new(), fn
      {_key, [_unique]}, ids -> ids
      {_key, recordings}, ids -> Enum.reduce(recordings, ids, &MapSet.put(&2, &1.id))
    end)
  end

  defp display_key(track) do
    {Normalize.normalize(track.tag_title || track.filename),
     Normalize.normalize(track.tag_artist)}
  end
end
