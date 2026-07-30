defmodule Beatgrid.BackupTest do
  # async: false — dumps write into an isolated :library_root on disk.
  use Beatgrid.DataCase, async: false, oban: true

  import Mox

  alias Beatgrid.Backup
  alias Beatgrid.Workers.DbBackupWorker

  @moduletag :tmp_dir

  setup :verify_on_exit!
  setup :set_mox_global
  setup :isolate_library_root

  test "dump writes a timestamped file via tmp+rename and broadcasts" do
    Backup.subscribe()

    expect(Beatgrid.Backup.DumperMock, :dump, fn cfg, tmp ->
      assert cfg[:database] == "beatgrid_test"
      assert String.ends_with?(tmp, ".dumping")
      File.write!(tmp, "dump-bytes")
      :ok
    end)

    assert {:ok, path} = Backup.dump()
    assert File.read!(path) == "dump-bytes"
    assert String.ends_with?(path, ".dump")
    assert [%{size: 10}] = Backup.list()
    assert_receive {:backup_tick}
  end

  test "a failed dump leaves no file behind" do
    expect(Beatgrid.Backup.DumperMock, :dump, fn _cfg, tmp ->
      File.write!(tmp, "partial")
      {:error, {:pg_dump_exit, 1, "boom"}}
    end)

    assert {:error, {:pg_dump_exit, 1, _}} = Backup.dump()
    assert Backup.list() == []
  end

  test "prune keeps only the newest 14 dumps" do
    dir = Path.join([Beatgrid.Library.library_root(), "_Backups", "DB"])
    File.mkdir_p!(dir)

    for i <- 1..16 do
      path = Path.join(dir, "beatgrid-2026-07-#{String.pad_leading("#{i}", 2, "0")}-000000.dump")
      File.write!(path, "old")
      File.touch!(path, {{2026, 7, i}, {0, 0, 0}})
    end

    expect(Beatgrid.Backup.DumperMock, :dump, fn _cfg, tmp ->
      File.write!(tmp, "new")
      :ok
    end)

    assert {:ok, _path} = Backup.dump()
    assert length(Backup.list()) == 14
    # the oldest fell off; the fresh one is first
    assert %{size: 3} = Backup.latest()
  end

  test "restore_command points pg_restore at the dump with the repo's config" do
    cmd = Backup.restore_command(%{path: "/x/beatgrid-1.dump"})
    assert cmd =~ "pg_restore"
    assert cmd =~ "beatgrid_test"
    assert cmd =~ "--clean --if-exists"
    assert cmd =~ "/x/beatgrid-1.dump"
  end

  test "the worker runs the dump" do
    expect(Beatgrid.Backup.DumperMock, :dump, fn _cfg, tmp ->
      File.write!(tmp, "ok")
      :ok
    end)

    assert :ok = perform_job(DbBackupWorker, %{})
    assert length(Backup.list()) == 1
  end
end
