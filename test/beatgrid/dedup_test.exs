defmodule Beatgrid.DedupTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Dedup

  describe "detect/0" do
    test "groups exact duplicates by content hash, keeping the highest-bitrate copy" do
      keeper = insert(:track, content_sha256: "abc", bitrate_kbps: 320, rel_path: "MPB/a.mp3")
      _other = insert(:track, content_sha256: "abc", bitrate_kbps: 128, rel_path: "MPB/b.mp3")
      _unique = insert(:track, content_sha256: "xyz", rel_path: "MPB/c.mp3")

      assert {:ok, %{exact: 1, fuzzy: 0}} = Dedup.detect()

      assert [group] = Dedup.list_groups()
      assert group.match_type == :exact_hash
      assert length(group.members) == 2

      assert %{is_keeper: true} = kept = Enum.find(group.members, & &1.is_keeper)
      assert kept.track_id == keeper.id
    end

    test "groups fuzzy duplicates by normalized artist + title" do
      insert(:track,
        content_sha256: "1",
        norm_artist: "chico buarque",
        norm_title: "sabia",
        rel_path: "x/a.mp3"
      )

      insert(:track,
        content_sha256: "2",
        norm_artist: "chico buarque",
        norm_title: "sabia",
        rel_path: "y/b.mp3"
      )

      assert {:ok, %{exact: 0, fuzzy: 1}} = Dedup.detect()
      assert [%{match_type: :fuzzy_meta, members: members}] = Dedup.list_groups()
      assert length(members) == 2
    end

    test "does not group tracks with blank normalized fields" do
      insert(:track, norm_artist: "", norm_title: "", content_sha256: "a")
      insert(:track, norm_artist: "", norm_title: "", content_sha256: "b")

      assert {:ok, %{exact: 0, fuzzy: 0}} = Dedup.detect()
      assert Dedup.list_groups() == []
    end

    test "is idempotent across re-runs" do
      insert(:track, content_sha256: "abc", rel_path: "a.mp3")
      insert(:track, content_sha256: "abc", rel_path: "b.mp3")

      {:ok, _} = Dedup.detect()
      {:ok, _} = Dedup.detect()

      assert length(Dedup.list_groups()) == 1
    end
  end
end
