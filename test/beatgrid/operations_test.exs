defmodule Beatgrid.OperationsTest do
  # async: false — undo_batch/1 touches disk and overrides :library_root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Organization

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  describe "record/1, list_by/1, count/1" do
    test "records an operation (defaults to :applied) and filters it back" do
      track = insert(:track)
      batch = Uniq.UUID.uuid7()

      assert {:ok, op} =
               Operations.record(%{
                 track_id: track.id,
                 kind: :rename,
                 from: "Old.mp3",
                 to: "New.mp3",
                 batch_id: batch
               })

      assert op.status == :applied
      assert Operations.count(batch_id: batch) == 1
      assert [found] = Operations.list_by(batch_id: batch, kind: :rename)
      assert found.id == op.id
      assert Operations.list_by(batch_id: batch, status: :undone) == []
    end

    test "requires kind, batch_id and track_id" do
      assert {:error, changeset} = Operations.record(%{from: "x"})
      assert %{kind: _, batch_id: _, track_id: _} = errors_on(changeset)
    end
  end

  describe "undo_batch/1" do
    @tag :tmp_dir
    test "reverts an applied rename and an applied move in one batch", %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", dir_name: "MPB")

      # --- applied rename fixture ---
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/Old.mp3"), "a")
      song = insert(:soundcharts_song, credit_name: "Artist", name: "New")

      rtrack =
        insert(:track,
          rel_path: "MPB/Old.mp3",
          filename: "Old.mp3",
          genre_folder: "mpb",
          soundcharts_song_id: song.id,
          sc_match_confidence: :high
        )

      {:ok, _} = NameSync.propose()
      {:ok, %{applied: 1}} = NameSync.apply_auto()
      [rename] = NameSync.list_by(status: :applied)

      # --- applied move fixture ---
      File.write!(Path.join(root, "_Inbox/song.mp3"), "audio")

      mtrack =
        insert(:track, rel_path: "_Inbox/song.mp3", filename: "song.mp3", genre_folder: nil)

      {:ok, move} =
        Organization.create_suggestion(%{
          track_id: mtrack.id,
          from_rel_path: "_Inbox/song.mp3",
          to_genre_folder: "mpb",
          source: :claude
        })

      {:ok, %{applied: 1}} = Organization.apply_batch([move])

      # --- log both into one operations batch ---
      batch = Uniq.UUID.uuid7()

      {:ok, _} =
        Operations.record(%{
          track_id: rtrack.id,
          kind: :rename,
          from: "Old.mp3",
          to: "Artist - New.mp3",
          batch_id: batch,
          suggestion_id: rename.id
        })

      {:ok, _} =
        Operations.record(%{
          track_id: mtrack.id,
          kind: :move,
          from: "_Inbox/song.mp3",
          to: "mpb",
          batch_id: batch,
          suggestion_id: move.id
        })

      assert {:ok, %{undone: 2, failed: 0}} = Operations.undo_batch(batch)

      # rename reverted on disk + suggestion :undone
      assert File.exists?(Path.join(root, "MPB/Old.mp3"))
      assert Tracks.get(rtrack.id).filename == "Old.mp3"
      assert NameSync.get(rename.id).status == :undone

      # move reverted on disk + suggestion :undone
      assert File.exists?(Path.join(root, "_Inbox/song.mp3"))
      assert Tracks.get(mtrack.id).rel_path == "_Inbox/song.mp3"
      assert Organization.get(move.id).status == :undone

      # operations themselves are now :undone
      assert Operations.count(batch_id: batch, status: :undone) == 2
    end

    @tag :tmp_dir
    test "reverts a manual move (suggestion_id: nil) back to its original folder", %{
      tmp_dir: root
    } do
      insert(:genre_folder, key: "mpb", dir_name: "MPB")
      insert(:genre_folder, key: "forro", dir_name: "Forró")

      # the file currently sits in Forró (it was moved there); undo sends it back to MPB
      File.mkdir_p!(Path.join(root, "Forró"))
      File.write!(Path.join(root, "Forró/x.mp3"), "audio")

      track =
        insert(:track,
          status: :present,
          rel_path: "Forró/x.mp3",
          filename: "x.mp3",
          genre_folder: "forro"
        )

      batch = Uniq.UUID.uuid7()

      {:ok, _} =
        Operations.record(%{
          track_id: track.id,
          kind: :move,
          from: "MPB/x.mp3",
          to: "forro",
          batch_id: batch,
          suggestion_id: nil
        })

      assert {:ok, %{undone: 1, failed: 0}} = Operations.undo_batch(batch)

      assert File.exists?(Path.join(root, "MPB/x.mp3"))
      refute File.exists?(Path.join(root, "Forró/x.mp3"))
      assert Tracks.get(track.id).rel_path == "MPB/x.mp3"
      assert Tracks.get(track.id).genre_folder == "mpb"
    end
  end
end
