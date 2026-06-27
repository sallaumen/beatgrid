defmodule Beatgrid.Dedup do
  @moduledoc """
  Detects duplicate tracks — exact (identical file hash) and fuzzy (same
  normalized artist + title) — and records them as reviewable groups, each with
  a suggested keeper (highest bitrate, then longest, then first by path).

  `detect/0` is idempotent: it rebuilds all groups from the current tracks.
  """
  alias Beatgrid.Dedup.{DedupQuery, DuplicateGroup, DuplicateMember}
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Repo

  defdelegate list_groups, to: DedupQuery
  defdelegate count_groups, to: DedupQuery

  @spec detect() :: {:ok, %{exact: non_neg_integer(), fuzzy: non_neg_integer()}}
  def detect do
    Repo.transact(fn ->
      Repo.delete_all(DuplicateMember)
      Repo.delete_all(DuplicateGroup)

      tracks = Tracks.list_by(status: :present)

      exact = group_exact(tracks)
      exact_ids = member_ids(exact)
      fuzzy = tracks |> Enum.reject(&MapSet.member?(exact_ids, &1.id)) |> group_fuzzy()

      Enum.each(exact, fn {signature, members} ->
        persist_group(:exact_hash, signature, members)
      end)

      Enum.each(fuzzy, fn {signature, members} ->
        persist_group(:fuzzy_meta, signature, members)
      end)

      {:ok, %{exact: length(exact), fuzzy: length(fuzzy)}}
    end)
  end

  defp group_exact(tracks) do
    tracks
    |> Enum.reject(&is_nil(&1.content_sha256))
    |> Enum.group_by(& &1.content_sha256)
    |> Enum.filter(fn {_signature, members} -> length(members) > 1 end)
  end

  defp group_fuzzy(tracks) do
    tracks
    |> Enum.filter(&fuzzy_key?/1)
    |> Enum.group_by(&fuzzy_signature/1)
    |> Enum.filter(fn {_signature, members} -> length(members) > 1 end)
  end

  defp fuzzy_key?(track), do: present?(track.norm_artist) and present?(track.norm_title)
  defp fuzzy_signature(track), do: "#{track.norm_artist} — #{track.norm_title}"
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp member_ids(groups) do
    for {_signature, members} <- groups, track <- members, into: MapSet.new(), do: track.id
  end

  defp persist_group(match_type, signature, members) do
    keeper = pick_keeper(members)

    {:ok, group} =
      %DuplicateGroup{}
      |> DuplicateGroup.changeset(%{
        match_type: match_type,
        signature: signature,
        keeper_track_id: keeper.id
      })
      |> Repo.insert()

    Enum.each(members, fn track ->
      %DuplicateMember{}
      |> DuplicateMember.changeset(%{
        group_id: group.id,
        track_id: track.id,
        is_keeper: track.id == keeper.id
      })
      |> Repo.insert!()
    end)
  end

  # Picks the best copy to keep: most by quality (fewest issues), then placement
  # (classified folder > present inbox > quarantined), then resolved (Soundcharts
  # match), then rating, bitrate, duration. Ties break deterministically by the
  # lower `rel_path`.
  defp pick_keeper(members) do
    members
    |> Enum.sort_by(fn t -> {-keeper_score(t), t.rel_path} end)
    |> List.first()
  end

  defp keeper_score(t) do
    -length(t.quality_issues || []) * 10_000 +
      placement_score(t) * 1_000 +
      if(t.soundcharts_song_id, do: 500, else: 0) +
      (t.rating || 0) * 20 +
      (t.bitrate_kbps || 0) / 10 +
      (t.duration_ms || 0) / 100_000
  end

  defp placement_score(%{status: :quarantined}), do: 0
  defp placement_score(%{genre_folder: nil}), do: 1
  defp placement_score(_classified), do: 2
end
