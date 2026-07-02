defmodule Beatgrid.Dedup do
  @moduledoc """
  Detects duplicate tracks — exact (identical file hash) and fuzzy (same
  normalized artist + title) — and records them as reviewable groups, each with
  a suggested keeper (highest bitrate, then longest, then first by path).

  `detect/0` is idempotent: it rebuilds all groups from the current tracks.
  """
  alias Beatgrid.Dedup.{DedupQuery, DuplicateGroup, DuplicateMember}
  alias Beatgrid.{Library, Operations, Repo}
  alias Beatgrid.Library.Tracks

  @topic "dedup"

  defdelegate list_groups, to: DedupQuery
  defdelegate count_groups, to: DedupQuery

  @doc """
  Pending (unresolved) duplicate groups, members + tracks + songs preloaded. Groups
  that dropped below 2 members (e.g. a member was hard-deleted, cascading its row)
  are degenerate and filtered out — a group of one isn't a duplicate.
  """
  @spec list_pending() :: [DuplicateGroup.t()]
  def list_pending do
    DedupQuery.list_pending() |> Enum.filter(&(length(&1.members) >= 2))
  end

  @doc "One duplicate group by id, members + tracks + songs preloaded, or nil."
  @spec get_group(Ecto.UUID.t()) :: DuplicateGroup.t() | nil
  def get_group(id), do: DedupQuery.get(id)

  @spec set_group_status(DuplicateGroup.t(), atom()) ::
          {:ok, DuplicateGroup.t()} | {:error, Ecto.Changeset.t()}
  def set_group_status(group, status),
    do: group |> DuplicateGroup.changeset(%{status: status}) |> Repo.update()

  @doc "Subscribe to dedup-progress events (`{:dedup_progress, payload}`)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Broadcast a dedup-progress event (contract: `Beatgrid.Events`)."
  @spec broadcast_progress(Beatgrid.Events.dedup_progress()) :: :ok
  def broadcast_progress(payload),
    do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:dedup_progress, payload})

  @doc """
  Resolves a group by keeping `keeper_track_id` and quarantining every other
  member's track (a reversible move into `_Quarantine`, never a delete). Sets the
  keeper flags, records one undoable `:quarantine` operation per quarantined track
  under a shared `batch_id`, and marks the group `:resolved`. Returns
  `{:ok, %{quarantined: n, batch_id: id}}`, or `{:error, :keeper_not_in_group}`.
  """
  @spec resolve_group(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{quarantined: non_neg_integer(), batch_id: Ecto.UUID.t()}}
          | {:error, term()}
  def resolve_group(group_id, keeper_track_id) do
    group = DedupQuery.get(group_id)
    members = group.members

    if Enum.any?(members, &(&1.track_id == keeper_track_id)) do
      batch_id = Uniq.UUID.uuid7()
      set_keeper(group, members, keeper_track_id)
      keeper_isrc = members |> Enum.find(&(&1.track_id == keeper_track_id)) |> member_isrc()

      quarantined =
        members
        # Skip the keeper, and never quarantine a DIFFERENT recording (a conflicting
        # ISRC) — that's a distinct version kept on purpose, not a duplicate.
        |> Enum.reject(fn m ->
          m.track_id == keeper_track_id or different_recording?(m, keeper_isrc)
        end)
        |> Enum.count(&quarantine_member(&1, batch_id))

      set_group_status(group, :resolved)
      {:ok, %{quarantined: quarantined, batch_id: batch_id}}
    else
      {:error, :keeper_not_in_group}
    end
  end

  @doc """
  True when `member` is a different recording than the keeper: it carries an ISRC
  that differs from the keeper's (including when the keeper has none — an ISRC the
  keeper lacks is reason enough to spare it). Spares distinct versions (a live or
  remaster with its own ISRC) from quarantine even when they share a fuzzy title.
  Also used by the UI to mark such members as kept.
  """
  @spec different_recording?(DuplicateMember.t(), String.t() | nil) :: boolean()
  def different_recording?(member, keeper_isrc) do
    member_isrc = member_isrc(member)
    is_binary(member_isrc) and member_isrc != keeper_isrc
  end

  @doc "The track's ISRC for a member (tag ISRC, else the linked Soundcharts song's), upcased; nil if none."
  @spec member_isrc(DuplicateMember.t() | nil) :: String.t() | nil
  def member_isrc(%{track: track}), do: track_isrc(track)
  def member_isrc(_member), do: nil

  defp track_isrc(%{tag_isrc: isrc}) when is_binary(isrc) and isrc != "",
    do: normalize_isrc(isrc)

  defp track_isrc(%{soundcharts_song: %{isrc: isrc}}) when is_binary(isrc) and isrc != "",
    do: normalize_isrc(isrc)

  defp track_isrc(_track), do: nil

  defp normalize_isrc(isrc), do: isrc |> String.trim() |> String.upcase()

  @doc "Marks a group `:resolved` without touching any file (the user dismissed it)."
  @spec ignore_group(Ecto.UUID.t()) ::
          {:ok, DuplicateGroup.t()} | {:error, Ecto.Changeset.t()}
  def ignore_group(group_id), do: group_id |> DedupQuery.get() |> set_group_status(:resolved)

  # Point the group at the chosen keeper and flip each member's is_keeper flag.
  defp set_keeper(group, members, keeper_track_id) do
    {:ok, _} =
      group |> DuplicateGroup.changeset(%{keeper_track_id: keeper_track_id}) |> Repo.update()

    Enum.each(members, fn member ->
      member
      |> DuplicateMember.changeset(%{is_keeper: member.track_id == keeper_track_id})
      |> Repo.update!()
    end)
  end

  # Quarantine one member's track (reversible move) and log a :quarantine op with
  # the ORIGINAL rel_path captured BEFORE the move, so the undo can restore it.
  defp quarantine_member(member, batch_id) do
    track = Tracks.get(member.track_id)
    orig = track.rel_path

    case Library.quarantine(track) do
      {:ok, _moved} ->
        Operations.record(%{
          track_id: track.id,
          kind: :quarantine,
          from: orig,
          to: "_Quarantine",
          batch_id: batch_id,
          suggestion_id: nil
        })

        true

      _ ->
        false
    end
  end

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
