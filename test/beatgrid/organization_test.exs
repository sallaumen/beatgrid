defmodule Beatgrid.OrganizationTest do
  # async: false — these tests override the global :library_root app env.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.{Library, Organization}
  alias Beatgrid.Library.Tracks

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      File.mkdir_p!(Path.join(root, "_Quarantine"))
    end

    :ok
  end

  describe "apply_batch/1 and undo/1" do
    @tag :tmp_dir
    test "moves the file into the genre folder, updates the track, then undoes it", %{
      tmp_dir: root
    } do
      insert(:genre_folder, key: "mpb", dir_name: "MPB")
      File.write!(Path.join(root, "_Inbox/song.mp3"), "audio")
      track = insert(:track, rel_path: "_Inbox/song.mp3", filename: "song.mp3", genre_folder: nil)

      {:ok, suggestion} =
        Organization.create_suggestion(%{
          track_id: track.id,
          from_rel_path: "_Inbox/song.mp3",
          to_genre_folder: "mpb",
          source: :rule
        })

      assert {:ok, %{applied: 1, failed: 0}} = Organization.apply_batch([suggestion])

      assert File.exists?(Path.join(root, "MPB/song.mp3"))
      refute File.exists?(Path.join(root, "_Inbox/song.mp3"))

      moved = Tracks.get(track.id)
      assert moved.rel_path == "MPB/song.mp3"
      assert moved.genre_folder == "mpb"
      assert Organization.get(suggestion.id).status == :applied

      assert {:ok, _} = Organization.undo(Organization.get(suggestion.id))
      assert File.exists?(Path.join(root, "_Inbox/song.mp3"))
      refute File.exists?(Path.join(root, "MPB/song.mp3"))
      assert Tracks.get(track.id).rel_path == "_Inbox/song.mp3"
      assert Organization.get(suggestion.id).status == :undone
    end

    @tag :tmp_dir
    test "never clobbers an existing destination — picks a unique name", %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", dir_name: "MPB")
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/dup.mp3"), "existing")
      File.write!(Path.join(root, "_Inbox/dup.mp3"), "incoming")
      track = insert(:track, rel_path: "_Inbox/dup.mp3", filename: "dup.mp3")

      {:ok, suggestion} =
        Organization.create_suggestion(%{
          track_id: track.id,
          from_rel_path: "_Inbox/dup.mp3",
          to_genre_folder: "mpb",
          source: :rule
        })

      assert {:ok, %{applied: 1}} = Organization.apply_batch([suggestion])

      assert File.read!(Path.join(root, "MPB/dup.mp3")) == "existing"
      assert Tracks.get(track.id).rel_path == "MPB/dup (2).mp3"
      assert File.read!(Path.join(root, "MPB/dup (2).mp3")) == "incoming"
    end
  end

  describe "quarantine/1" do
    @tag :tmp_dir
    test "moves a track into _Quarantine and flags its status", %{tmp_dir: root} do
      File.write!(Path.join(root, "_Inbox/bad.mp3"), "x")
      track = insert(:track, rel_path: "_Inbox/bad.mp3", filename: "bad.mp3")

      assert {:ok, q} = Library.quarantine(track)
      assert q.status == :quarantined
      assert q.rel_path == "_Quarantine/bad.mp3"
      assert File.exists?(Path.join(root, "_Quarantine/bad.mp3"))
      refute File.exists?(Path.join(root, "_Inbox/bad.mp3"))
    end
  end
end
