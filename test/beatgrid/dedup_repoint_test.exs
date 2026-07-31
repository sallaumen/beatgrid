defmodule Beatgrid.DedupRepointTest do
  # async: false — these tests override the global :library_root app env.
  use Beatgrid.DataCase, async: false

  import Beatgrid.Factory

  alias Beatgrid.Dedup
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Sets

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "Forró Roots"))
    end

    :ok
  end

  # The silent party-breaker from the field: dedup quarantined a copy that was
  # a MEMBER of two gig sets, and the entries kept pointing at the ghost.
  @tag :tmp_dir
  test "resolving a duplicate repoints the loser's set seats to the keeper", %{tmp_dir: root} do
    File.write!(Path.join(root, "Forró Roots/a.mp3"), "same-bytes")
    File.write!(Path.join(root, "Forró Roots/a (2).mp3"), "same-bytes")

    keeper =
      insert(:track, content_sha256: "dup", rel_path: "Forró Roots/a.mp3", filename: "a.mp3")

    loser =
      insert(:track,
        content_sha256: "dup",
        rel_path: "Forró Roots/a (2).mp3",
        filename: "a (2).mp3"
      )

    {:ok, set} = Sets.create("Festa")
    other = insert(:track, status: :present)
    {:ok, _} = Sets.append(set, loser)
    {:ok, _} = Sets.append(set, other)

    {:ok, _} = Dedup.detect()
    [group] = Dedup.list_pending()
    assert {:ok, %{quarantined: 1}} = Dedup.resolve_group(group.id, keeper.id)

    # the file left the library, but the set seat now belongs to the keeper
    assert Tracks.get(loser.id).status == :quarantined
    assert Enum.map(Sets.entries(set), & &1.track.id) == [keeper.id, other.id]
  end
end
