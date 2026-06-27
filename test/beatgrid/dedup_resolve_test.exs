defmodule Beatgrid.DedupResolveTest do
  # async: false — resolve_group/1 touches disk and overrides :library_root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Dedup
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Operations

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      File.mkdir_p!(Path.join(root, "_Quarantine"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  describe "resolve_group/2" do
    @tag :tmp_dir
    test "quarantines non-keepers (reversibly) and marks the group resolved", %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", dir_name: "MPB")
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/a.mp3"), "x")
      File.write!(Path.join(root, "MPB/b.mp3"), "x")

      keep =
        insert(:track,
          status: :present,
          content_sha256: "h",
          bitrate_kbps: 320,
          genre_folder: "mpb",
          rel_path: "MPB/a.mp3",
          filename: "a.mp3"
        )

      dup =
        insert(:track,
          status: :present,
          content_sha256: "h",
          bitrate_kbps: 128,
          genre_folder: "mpb",
          rel_path: "MPB/b.mp3",
          filename: "b.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      {:ok, %{quarantined: 1, batch_id: bid}} = Dedup.resolve_group(g.id, keep.id)
      assert Tracks.get(dup.id).status == :quarantined
      assert Tracks.get(keep.id).status == :present
      assert File.exists?(Path.join(root, "_Quarantine/b.mp3"))
      refute File.exists?(Path.join(root, "MPB/b.mp3"))
      assert Dedup.get_group(g.id).status == :resolved

      {:ok, %{undone: 1}} = Operations.undo_batch(bid)
      assert Tracks.get(dup.id).status == :present
      assert Tracks.get(dup.id).rel_path == "MPB/b.mp3"
      assert Tracks.get(dup.id).genre_folder == "mpb"
      assert File.exists?(Path.join(root, "MPB/b.mp3"))
      refute File.exists?(Path.join(root, "_Quarantine/b.mp3"))
    end

    @tag :tmp_dir
    test "sets the keeper flags on the group and members", %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", dir_name: "MPB")
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/a.mp3"), "x")
      File.write!(Path.join(root, "MPB/b.mp3"), "x")

      a =
        insert(:track,
          status: :present,
          content_sha256: "h",
          genre_folder: "mpb",
          rel_path: "MPB/a.mp3",
          filename: "a.mp3"
        )

      b =
        insert(:track,
          status: :present,
          content_sha256: "h",
          genre_folder: "mpb",
          rel_path: "MPB/b.mp3",
          filename: "b.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      {:ok, _} = Dedup.resolve_group(g.id, b.id)

      reloaded = Dedup.get_group(g.id)
      assert reloaded.keeper_track_id == b.id
      keeper_member = Enum.find(reloaded.members, & &1.is_keeper)
      assert keeper_member.track_id == b.id
      non_keeper = Enum.find(reloaded.members, &(not &1.is_keeper))
      assert non_keeper.track_id == a.id
    end

    test "returns an error when the keeper is not in the group" do
      a = insert(:track, content_sha256: "h", rel_path: "MPB/a.mp3")
      _b = insert(:track, content_sha256: "h", rel_path: "MPB/b.mp3")
      stranger = insert(:track, content_sha256: "z", rel_path: "MPB/c.mp3")

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      assert {:error, :keeper_not_in_group} = Dedup.resolve_group(g.id, stranger.id)
      assert Dedup.get_group(g.id).status == :pending
      _ = a
    end
  end

  describe "ignore_group/1" do
    test "resolves with no quarantine" do
      insert(:track,
        content_sha256: "1",
        norm_artist: "chico buarque",
        norm_title: "sabia",
        rel_path: "x/a.mp3",
        status: :present
      )

      insert(:track,
        content_sha256: "2",
        norm_artist: "chico buarque",
        norm_title: "sabia",
        rel_path: "y/b.mp3",
        status: :present
      )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      assert {:ok, _} = Dedup.ignore_group(g.id)
      assert Dedup.get_group(g.id).status == :resolved
      # both tracks untouched
      assert Enum.all?(Tracks.list_by(status: :present), &(&1.status == :present))
      assert Tracks.count(status: :present) == 2
    end
  end

  describe "list_pending/0" do
    test "returns only pending groups, with members + tracks preloaded" do
      insert(:track, content_sha256: "h", rel_path: "MPB/a.mp3", status: :present)
      insert(:track, content_sha256: "h", rel_path: "MPB/b.mp3", status: :present)
      {:ok, _} = Dedup.detect()

      [g] = Dedup.list_pending()
      assert g.status == :pending
      assert [_, _] = g.members
      assert Enum.all?(g.members, &(%Beatgrid.Library.Track{} = &1.track))

      # once resolved it drops out of list_pending
      {:ok, _} = Dedup.ignore_group(g.id)
      assert Dedup.list_pending() == []
    end
  end

  describe "subscribe/0 + broadcast_progress/1" do
    test "subscribers receive dedup_progress events" do
      :ok = Dedup.subscribe()
      :ok = Dedup.broadcast_progress(%{status: :running})
      assert_receive {:dedup_progress, %{status: :running}}
    end
  end
end
