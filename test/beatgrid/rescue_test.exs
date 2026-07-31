defmodule Beatgrid.RescueTest do
  # async: false — isolate_library_root swaps a GLOBAL app env; a concurrent
  # test file reading the root mid-swap sees the wrong library.
  use Beatgrid.DataCase, async: false, oban: true

  import Beatgrid.Factory
  import Mox

  @moduletag :tmp_dir

  setup :verify_on_exit!
  setup :isolate_library_root

  alias Beatgrid.Audio.IntegrityCheckerMock
  alias Beatgrid.Audio.LoudnessMock
  alias Beatgrid.Library
  alias Beatgrid.Operations
  alias Beatgrid.Rescue
  alias Beatgrid.Workers.IntegrityCheckWorker

  defp root, do: Library.library_root()

  defp write_file(rel, content) do
    path = Path.join(root(), rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp gain_backup!(track, content \\ "original-bytes") do
    backup_rel = Path.join(["_Backups", "Gain", track.id, Uniq.UUID.uuid7(), track.rel_path])
    write_file(backup_rel, content)

    {:ok, _op} =
      Operations.record(%{
        track_id: track.id,
        kind: :gain,
        status: :applied,
        from: "3.5",
        to: backup_rel,
        batch_id: Uniq.UUID.uuid7()
      })

    backup_rel
  end

  describe "check/1" do
    test "persists ok, corrupt, and missing-file verdicts" do
      track = insert(:track, status: :present, rel_path: "a.mp3")

      expect(IntegrityCheckerMock, :check, fn _path -> :ok end)
      assert {:ok, %{integrity_status: :ok, integrity_error: nil}} = Rescue.check(track)

      expect(IntegrityCheckerMock, :check, fn _path -> {:error, {:corrupt, "bad frame"}} end)
      assert {:ok, checked} = Rescue.check(track)
      assert checked.integrity_status == :corrupt
      assert checked.integrity_error == "bad frame"
      assert checked.integrity_checked_at

      expect(IntegrityCheckerMock, :check, fn _path -> {:error, :enoent} end)
      assert {:ok, %{integrity_status: :missing_file}} = Rescue.check(track)
    end

    test "broadcasts the verdict for the live census" do
      :ok = Rescue.subscribe()
      track = insert(:track, status: :present, rel_path: "b.mp3")

      expect(IntegrityCheckerMock, :check, fn _path -> :ok end)
      {:ok, _} = Rescue.check(track)

      assert_receive {:integrity_checked, id}
      assert id == track.id
    end
  end

  test "enqueue_check_all targets every present track" do
    present = insert(:track, status: :present, rel_path: "p.mp3")
    _quarantined = insert(:track, status: :quarantined, rel_path: "_Quarantine/q.mp3")

    assert {:ok, 1} = Rescue.enqueue_check_all()
    assert_enqueued(worker: IntegrityCheckWorker, args: %{track_id: present.id})
  end

  describe "damaged/0" do
    test "lists ghosts and corrupt tracks with backup availability" do
      with_backup =
        insert(:track,
          status: :present,
          rel_path: "Forró/com.mp3",
          integrity_status: :missing_file
        )

      gain_backup!(with_backup)

      no_backup =
        insert(:track, status: :present, rel_path: "Forró/sem.mp3", integrity_status: :corrupt)

      _healthy = insert(:track, status: :present, rel_path: "ok.mp3", integrity_status: :ok)

      damaged = Rescue.damaged()

      assert Enum.sort(Enum.map(damaged, &{&1.track.id, is_binary(&1.backup_rel)})) ==
               Enum.sort([{with_backup.id, true}, {no_backup.id, false}])

      %{backup_rel: rel} = Enum.find(damaged, &(&1.track.id == with_backup.id))
      assert String.starts_with?(rel, "_Backups/Gain/")
    end

    test "a backup whose file was pruned from disk counts as no backup" do
      track =
        insert(:track, status: :present, rel_path: "Forró/x.mp3", integrity_status: :corrupt)

      backup_rel = gain_backup!(track)
      File.rm!(Path.join(root(), backup_rel))

      assert [%{backup_rel: nil}] = Rescue.damaged()
    end
  end

  describe "restore_from_backup/1" do
    test "brings the file back, resets gain, and re-checks integrity" do
      track =
        insert(:track,
          status: :present,
          rel_path: "Forró/fantasma.mp3",
          integrity_status: :missing_file,
          gain_applied_db: 3.5
        )

      gain_backup!(track, "original-audio")

      expect(LoudnessMock, :measure, fn _path ->
        {:ok, %{lufs: -16.2, true_peak: -2.0, lra: 5.0}}
      end)

      expect(IntegrityCheckerMock, :check, fn _path -> :ok end)

      assert {:ok, restored} = Rescue.restore_from_backup(track)

      assert File.read!(Path.join(root(), track.rel_path)) == "original-audio"
      assert restored.integrity_status == :ok
      assert restored.gain_applied_db == nil
    end

    test "without a backup on disk it refuses instead of guessing" do
      track = insert(:track, status: :present, rel_path: "s.mp3", integrity_status: :corrupt)
      assert {:error, :no_backup} = Rescue.restore_from_backup(track)
    end
  end

  test "restore_all_from_backup restores what it can and counts the rest" do
    restorable =
      insert(:track,
        status: :present,
        rel_path: "Forró/volta.mp3",
        integrity_status: :missing_file
      )

    gain_backup!(restorable)

    _stuck = insert(:track, status: :present, rel_path: "fica.mp3", integrity_status: :corrupt)

    expect(LoudnessMock, :measure, fn _path ->
      {:ok, %{lufs: -15.0, true_peak: -1.5, lra: 4.0}}
    end)

    expect(IntegrityCheckerMock, :check, fn _path -> :ok end)

    assert {:ok, %{restored: 1, failed: 0}} = Rescue.restore_all_from_backup()
    assert [%{track: %{integrity_status: :corrupt}}] = Rescue.damaged()
  end

  describe "quarantine" do
    test "a row whose file left _Quarantine is flagged as a ghost" do
      insert(:track, status: :quarantined, rel_path: "_Quarantine/sumida.mp3")

      assert [%{file?: false}] = Rescue.quarantined()
    end

    test "quarantined/0 exposes the original path; restore returns the file and the row" do
      track = insert(:track, status: :quarantined, rel_path: "_Quarantine/dupla.mp3")
      write_file(track.rel_path, "quarantined-audio")
      File.mkdir_p!(Path.join(root(), "Forró"))

      {:ok, op} =
        Operations.record(%{
          track_id: track.id,
          kind: :quarantine,
          status: :applied,
          from: "Forró/dupla.mp3",
          to: track.rel_path,
          batch_id: Uniq.UUID.uuid7()
        })

      assert [%{restore_rel: "Forró/dupla.mp3"}] = Rescue.quarantined()
      assert File.exists?(Path.join(root(), track.rel_path))

      assert {:ok, restored} = Rescue.restore_from_quarantine(track)
      assert restored.status == :present
      # do_move never overwrites: the name may get a uniquifying suffix, but it
      # must land back in the original folder, out of _Quarantine.
      assert Path.dirname(restored.rel_path) == "Forró"
      assert File.exists?(Path.join(root(), restored.rel_path))
      refute File.exists?(Path.join(root(), "_Quarantine/dupla.mp3"))
      assert Repo.reload!(op).status == :undone
    end

    test "a quarantined row without an operation refuses the restore" do
      track = insert(:track, status: :quarantined, rel_path: "_Quarantine/orfa.mp3")
      assert {:error, :no_quarantine_origin} = Rescue.restore_from_quarantine(track)
    end
  end
end
