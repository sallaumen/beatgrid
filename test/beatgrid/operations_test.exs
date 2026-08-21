defmodule Beatgrid.OperationsTest do
  # async: false — undo_batch/1 touches disk and overrides :library_root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Organization

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
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

  describe "recent_batches/1" do
    test "groups the disk writes into batches a DJ can still undo" do
      track = insert(:track)
      older = Uniq.UUID.uuid7()
      newer = Uniq.UUID.uuid7()

      for {batch, kind} <- [{older, :rename}, {newer, :move}, {newer, :tag}] do
        {:ok, _} =
          Operations.record(%{track_id: track.id, kind: kind, batch_id: batch, to: "x"})
      end

      # Real batches are minutes apart; two uuid7() in a row share a millisecond
      # and would leave the ordering to the v7 random bits. Age the older batch
      # so the test pins the actual ordering column, not a coin flip.
      age_batch(older, -60)

      assert [first, second] = Operations.recent_batches(limit: 5)

      # Newest first: the DJ undoes what he just did, not what he did an hour ago.
      assert first.batch_id == newer
      assert first.count == 2
      assert first.undoable?
      assert second.batch_id == older
      assert second.count == 1
    end

    test "a batch already undone is listed but no longer offers an undo" do
      track = insert(:track)
      batch = Uniq.UUID.uuid7()
      {:ok, op} = Operations.record(%{track_id: track.id, kind: :rename, batch_id: batch})
      {:ok, _} = op |> Ecto.Changeset.change(status: :undone) |> Beatgrid.Repo.update()

      assert [only] = Operations.recent_batches(limit: 5)
      assert only.batch_id == batch
      refute only.undoable?
    end

    test "same-second batches fall back to the time-ordered batch_id" do
      track = insert(:track)
      # Hand-picked v7-shaped ids where byte order is unambiguous.
      low = "01900000-0000-7000-8000-000000000001"
      high = "01900000-0000-7000-8000-000000000002"

      for batch <- [high, low] do
        {:ok, _} = Operations.record(%{track_id: track.id, kind: :rename, batch_id: batch})
      end

      # Same inserted_at second for both — only the id can order them.
      assert [first, second] = Operations.recent_batches(limit: 5)
      assert first.batch_id == high
      assert second.batch_id == low
    end

    defp age_batch(batch_id, seconds) do
      import Ecto.Query

      Beatgrid.Repo.update_all(
        from(o in Beatgrid.Operations.Operation, where: o.batch_id == ^batch_id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), seconds, :second)]
      )
    end

    test "gain batches stay out: the Painel owns those, with their own restore" do
      track = insert(:track)

      {:ok, _} =
        Operations.record(%{track_id: track.id, kind: :gain, batch_id: Uniq.UUID.uuid7()})

      assert Operations.recent_batches(limit: 5) == []
    end
  end

  describe "undo_batch/1" do
    @tag :tmp_dir
    test "reverts an applied rename and an applied move in one batch", %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", dir_name: "MPB")

      # --- applied rename fixture ---
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/Old.mp3"), "a")

      rtrack =
        insert(:track,
          rel_path: "MPB/Old.mp3",
          filename: "Old.mp3",
          genre_folder: "mpb",
          soundcharts_song: build(:soundcharts_song, credit_name: "Artist", name: "New"),
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
