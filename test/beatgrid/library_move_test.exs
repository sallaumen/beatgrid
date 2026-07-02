defmodule Beatgrid.LibraryMoveTest do
  # async: false — moves touch disk and override :library_root; set_mox_global
  # so the move's Tagging write reaches the stub from the LiveView-less call.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Operations

  setup :set_mox_global
  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
    end

    # The genre tag write goes through the Tagging.Writer port (mocked).
    stub(Beatgrid.Tagging.Mock, :write_genre, fn _path, _genre -> :ok end)
    :ok
  end

  describe "move_to_folder/2" do
    @tag :tmp_dir
    test "moves the file, updates the track, records an undoable op, writes the tag", %{
      tmp_dir: root
    } do
      insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
      insert(:genre_folder, key: "forro", display_name: "Forró", dir_name: "Forró")
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/x.mp3"), "bytes")

      track =
        insert(:track,
          status: :present,
          rel_path: "MPB/x.mp3",
          filename: "x.mp3",
          genre_folder: "mpb"
        )

      assert {:ok, moved, batch_id} = Library.move_to_folder(track, "forro")
      assert moved.genre_folder == "forro"
      assert moved.rel_path == "Forró/x.mp3"
      assert File.exists?(Path.join(root, "Forró/x.mp3"))
      refute File.exists?(Path.join(root, "MPB/x.mp3"))

      assert [op] = Operations.list_by(batch_id: batch_id)
      assert op.kind == :move
      assert op.suggestion_id == nil
      assert op.from == "MPB/x.mp3"
      assert op.to == "forro"

      # the move is undoable through the operations log
      assert {:ok, %{undone: 1, failed: 0}} = Operations.undo_batch(batch_id)
      assert Tracks.get(track.id).genre_folder == "mpb"
      assert File.exists?(Path.join(root, "MPB/x.mp3"))
      refute File.exists?(Path.join(root, "Forró/x.mp3"))
    end

    @tag :tmp_dir
    test "rejects an unknown folder and a no-op move into the current folder", %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/x.mp3"), "bytes")

      track =
        insert(:track,
          status: :present,
          rel_path: "MPB/x.mp3",
          filename: "x.mp3",
          genre_folder: "mpb"
        )

      assert {:error, :unknown_folder} = Library.move_to_folder(track, "nope")
      assert {:error, :already_there} = Library.move_to_folder(track, "mpb")
    end
  end

  describe "move_many/2" do
    @tag :tmp_dir
    test "moves several tracks under one batch and counts moved/failed", %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
      insert(:genre_folder, key: "forro", display_name: "Forró", dir_name: "Forró")
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/a.mp3"), "a")
      File.write!(Path.join(root, "MPB/b.mp3"), "b")

      a =
        insert(:track,
          status: :present,
          rel_path: "MPB/a.mp3",
          filename: "a.mp3",
          genre_folder: "mpb"
        )

      b =
        insert(:track,
          status: :present,
          rel_path: "MPB/b.mp3",
          filename: "b.mp3",
          genre_folder: "mpb"
        )

      assert %{moved: 2, failed: 0, batch_id: batch_id} =
               Library.move_many([a.id, b.id], "forro")

      assert is_binary(batch_id)
      assert Tracks.get(a.id).genre_folder == "forro"
      assert Tracks.get(b.id).genre_folder == "forro"
      assert Operations.count(batch_id: batch_id) == 2

      # a missing id is counted as failed, not crashed
      assert %{moved: 0, failed: 1} = Library.move_many([Ecto.UUID.generate()], "forro")
    end
  end
end
