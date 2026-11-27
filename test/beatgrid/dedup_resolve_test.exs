defmodule Beatgrid.DedupResolveTest do
  # async: false — resolve_group/1 touches disk and overrides :library_root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Dedup
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Operations

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      File.mkdir_p!(Path.join(root, "_Quarantine"))
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

    @tag :tmp_dir
    test "keeps a member with a different ISRC — a distinct recording, not a dup", %{
      tmp_dir: root
    } do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/a.mp3"), "x")
      File.write!(Path.join(root, "MPB/b.mp3"), "y")

      keep =
        insert(:track,
          status: :present,
          content_sha256: "h1",
          norm_artist: "luiz gonzaga",
          norm_title: "asa branca",
          tag_isrc: "BRAAA0000001",
          rel_path: "MPB/a.mp3",
          filename: "a.mp3"
        )

      # Same fuzzy signature, but a DIFFERENT ISRC → a distinct recording/version.
      diff =
        insert(:track,
          status: :present,
          content_sha256: "h2",
          norm_artist: "luiz gonzaga",
          norm_title: "asa branca",
          tag_isrc: "BRBBB0000002",
          rel_path: "MPB/b.mp3",
          filename: "b.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      {:ok, %{quarantined: 0}} = Dedup.resolve_group(g.id, keep.id)

      assert Tracks.get(keep.id).status == :present
      # the different recording is spared on purpose
      assert Tracks.get(diff.id).status == :present
    end

    @tag :tmp_dir
    test "spares a member carrying an ISRC the keeper lacks", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/a.mp3"), "x")
      File.write!(Path.join(root, "MPB/b.mp3"), "y")

      # Keeper has no ISRC (e.g. a YouTube rip); the member is a distinct recording
      # with its own ISRC → spared, not quarantined.
      keep =
        insert(:track,
          status: :present,
          content_sha256: "h1",
          norm_artist: "artist",
          norm_title: "song",
          tag_isrc: nil,
          rel_path: "MPB/a.mp3",
          filename: "a.mp3"
        )

      diff =
        insert(:track,
          status: :present,
          content_sha256: "h2",
          norm_artist: "artist",
          norm_title: "song",
          tag_isrc: "BRZZZ0000001",
          rel_path: "MPB/b.mp3",
          filename: "b.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      {:ok, %{quarantined: 0}} = Dedup.resolve_group(g.id, keep.id)
      assert Tracks.get(diff.id).status == :present
    end

    @tag :tmp_dir
    test "two concurrent confirmations cannot quarantine both copies", %{tmp_dir: root} do
      File.write!(Path.join(root, "_Inbox/a.mp3"), "x")
      File.write!(Path.join(root, "_Inbox/b.mp3"), "x")

      a =
        insert(:track, content_sha256: "concurrent", rel_path: "_Inbox/a.mp3", filename: "a.mp3")

      b =
        insert(:track, content_sha256: "concurrent", rel_path: "_Inbox/b.mp3", filename: "b.mp3")

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()
      parent = self()

      tasks =
        for track <- [a, b] do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :resolve -> Dedup.resolve_group(g.id, track.id)
            end
          end)
        end

      for _ <- tasks do
        assert_receive {:ready, _}, 1000
      end

      Enum.each(tasks, &send(&1.pid, :resolve))
      results = Enum.map(tasks, &Task.await(&1, 5000))
      assert Enum.count(results, &match?({:ok, %{quarantined: 1, failed: []}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :group_not_pending}, &1)) == 1
      assert Enum.count([a.id, b.id], &(Tracks.get(&1).status == :present)) == 1
      assert Enum.count([a.id, b.id], &(Tracks.get(&1).status == :quarantined)) == 1
    end

    @tag :tmp_dir
    test "all failed moves leave the group pending and log no phantom operations", %{
      tmp_dir: root
    } do
      File.write!(Path.join(root, "_Inbox/keeper.mp3"), "x")

      keep =
        insert(:track,
          content_sha256: "allfail",
          rel_path: "_Inbox/keeper.mp3",
          filename: "keeper.mp3"
        )

      lost =
        insert(:track,
          content_sha256: "allfail",
          rel_path: "_Inbox/missing.mp3",
          filename: "missing.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      assert {:ok,
              %{quarantined: 0, failed: [%{track_id: id, reason: :source_missing}], batch_id: bid}} =
               Dedup.resolve_group(g.id, keep.id)

      assert id == lost.id
      assert Dedup.get_group(g.id).status == :pending
      assert [] == Operations.list_by(batch_id: bid)
      assert Tracks.get(lost.id).status == :present
    end

    @tag :tmp_dir
    test "mixed moves log only successes, keep the group pending and retry only unquarantined files",
         %{tmp_dir: root} do
      File.write!(Path.join(root, "_Inbox/keeper.mp3"), "x")
      File.write!(Path.join(root, "_Inbox/good.mp3"), "x")

      keep =
        insert(:track,
          content_sha256: "mixed",
          rel_path: "_Inbox/keeper.mp3",
          filename: "keeper.mp3"
        )

      good =
        insert(:track, content_sha256: "mixed", rel_path: "_Inbox/good.mp3", filename: "good.mp3")

      lost =
        insert(:track,
          content_sha256: "mixed",
          rel_path: "_Inbox/missing.mp3",
          filename: "missing.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      assert {:ok, %{quarantined: 1, failed: [%{track_id: id}], batch_id: first_batch}} =
               Dedup.resolve_group(g.id, keep.id)

      assert id == lost.id
      assert Dedup.get_group(g.id).status == :pending

      assert [%{track_id: good_id, from: "_Inbox/good.mp3", to: "_Quarantine/good.mp3"}] =
               Operations.list_by(batch_id: first_batch)

      assert good_id == good.id
      assert Tracks.get(good.id).status == :quarantined
      assert {:error, :keeper_unavailable} = Dedup.resolve_group(g.id, good.id)

      File.write!(Path.join(root, "_Inbox/missing.mp3"), "x")

      assert {:ok, %{quarantined: 1, failed: [], batch_id: second_batch}} =
               Dedup.resolve_group(g.id, keep.id)

      assert second_batch != first_batch
      assert [%{track_id: lost_id}] = Operations.list_by(batch_id: second_batch)
      assert lost_id == lost.id
      assert Tracks.get(lost.id).status == :quarantined
      assert Dedup.get_group(g.id).status == :resolved
    end

    @tag :tmp_dir
    test "a failed move first does not prevent the later copy from being quarantined", %{
      tmp_dir: root
    } do
      File.write!(Path.join(root, "_Inbox/keep.mp3"), "x")
      File.write!(Path.join(root, "_Inbox/z-good.mp3"), "x")

      keep =
        insert(:track,
          content_sha256: "ordered",
          rel_path: "_Inbox/keep.mp3",
          filename: "keep.mp3"
        )

      missing =
        insert(:track,
          content_sha256: "ordered",
          rel_path: "_Inbox/a-missing.mp3",
          filename: "a-missing.mp3"
        )

      good =
        insert(:track,
          content_sha256: "ordered",
          rel_path: "_Inbox/z-good.mp3",
          filename: "z-good.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()

      assert {:ok, %{quarantined: 1, failed: [%{track_id: id}], batch_id: bid}} =
               Dedup.resolve_group(g.id, keep.id)

      assert id == missing.id
      assert Dedup.get_group(g.id).status == :pending
      assert Tracks.get(good.id).status == :quarantined
      assert [%{track_id: good_id}] = Operations.list_by(batch_id: bid)
      assert good_id == good.id
    end

    @tag :tmp_dir
    test "a missing keeper cannot cause good copies to be quarantined", %{tmp_dir: root} do
      File.write!(Path.join(root, "_Inbox/good.mp3"), "x")

      keep =
        insert(:track,
          content_sha256: "missingkeeper",
          rel_path: "_Inbox/lost.mp3",
          filename: "lost.mp3"
        )

      good =
        insert(:track,
          content_sha256: "missingkeeper",
          rel_path: "_Inbox/good.mp3",
          filename: "good.mp3"
        )

      {:ok, _} = Dedup.detect()
      [g] = Dedup.list_pending()
      assert {:error, :keeper_unavailable} = Dedup.resolve_group(g.id, keep.id)
      assert Tracks.get(good.id).status == :present
      assert File.exists?(Path.join(root, "_Inbox/good.mp3"))
      assert Dedup.get_group(g.id).status == :pending
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
