defmodule Beatgrid.LoudnessTest do
  use Beatgrid.DataCase, async: false, oban: true

  import Mox
  import Beatgrid.Factory

  alias Beatgrid.Audio.{FfmpegLoudness, GainApplierMock, LoudnessMock}
  alias Beatgrid.Library.Track
  alias Beatgrid.Loudness
  alias Beatgrid.Operations
  alias Beatgrid.Workers.{GainApplyWorker, LoudnessWorker}

  setup :verify_on_exit!

  setup tags do
    if root = tags[:tmp_dir] do
      previous = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, previous) end)
    end

    :ok
  end

  describe "gain_db/2 (target -14 LUFS, ceiling -1 dBTP)" do
    test "nil loudness → nil", do: assert(Loudness.gain_db(nil, -1.0) == nil)

    test "boosts a quiet track toward the target",
      do: assert(Loudness.gain_db(-20.0, -8.0) == 6.0)

    test "cuts a loud track", do: assert(Loudness.gain_db(-8.0, -0.5) == -6.0)

    test "caps the boost at the true-peak ceiling",
      do: assert(Loudness.gain_db(-20.0, -2.0) == 1.0)

    test "uncapped boost when true peak is unknown",
      do: assert(Loudness.gain_db(-20.0, nil) == 6.0)
  end

  describe "gain eligibility" do
    test "uses the configured tolerance to decide whether a track needs gain" do
      assert Loudness.gain_tolerance_db() == 1.0

      refute Loudness.needs_gain?(%Track{loudness_lufs: -14.5, true_peak_dbtp: -6.0})
      assert Loudness.needs_gain?(%Track{loudness_lufs: -15.2, true_peak_dbtp: -6.0})
      assert Loudness.needs_gain?(%Track{loudness_lufs: -11.0, true_peak_dbtp: -0.2})
      refute Loudness.needs_gain?(%Track{loudness_lufs: nil, true_peak_dbtp: nil})
    end

    test "lists only measured present tracks that still need gain applied" do
      _within_tolerance =
        insert(:track,
          status: :present,
          loudness_lufs: -14.5,
          true_peak_dbtp: -6.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      boost =
        insert(:track,
          status: :present,
          loudness_lufs: -15.2,
          true_peak_dbtp: -6.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      cut =
        insert(:track,
          status: :present,
          loudness_lufs: -11.0,
          true_peak_dbtp: -0.2,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      _already_applied =
        insert(:track,
          status: :present,
          loudness_lufs: -20.0,
          true_peak_dbtp: -8.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z],
          gain_applied_at: ~U[2026-01-01 00:00:01Z],
          gain_applied_db: 6.0
        )

      _unmeasured = insert(:track, status: :present, loudness_lufs: nil)
      _missing = insert(:track, status: :missing, loudness_lufs: -20.0, true_peak_dbtp: -8.0)

      assert Enum.map(Loudness.gain_pending(), & &1.id) == [boost.id, cut.id]
      assert Loudness.gain_pending_count() == 2
    end
  end

  describe "FfmpegLoudness.parse/1" do
    test "reads input_i / input_tp / input_lra" do
      out = """
      [Parsed_loudnorm_0 @ 0x0]
      {
        "input_i" : "-14.50",
        "input_tp" : "-1.20",
        "input_lra" : "7.30",
        "input_thresh" : "-24.70",
        "output_i" : "-14.00"
      }
      """

      assert {:ok, %{lufs: -14.5, true_peak: -1.2, lra: 7.3}} = FfmpegLoudness.parse(out)
    end

    test "silence (-inf integrated) → error",
      do:
        assert(
          {:error, _} = FfmpegLoudness.parse(~s|{ "input_i" : "-inf", "input_tp" : "-120.0" }|)
        )

    test "no JSON block → error", do: assert({:error, _} = FfmpegLoudness.parse("no data here"))
  end

  describe "measure_track/1" do
    test "stores LUFS + true peak (and stamps attempted) from the adapter" do
      track = insert(:track, status: :present)

      expect(LoudnessMock, :measure, fn _path ->
        {:ok, %{lufs: -16.2, true_peak: -2.0, lra: 5.0}}
      end)

      assert {:ok, t} = Loudness.measure_track(track)
      assert t.loudness_lufs == -16.2
      assert t.true_peak_dbtp == -2.0
      assert t.loudness_attempted_at != nil
      assert t.loudness_measurement_origin == :library_file
    end

    test "marks attempted (no value) for a deterministically unmeasurable file" do
      track = insert(:track, status: :present)
      expect(LoudnessMock, :measure, fn _path -> {:error, :no_loudness_data} end)

      assert {:ok, t} = Loudness.measure_track(track)
      assert t.loudness_lufs == nil
      assert t.loudness_attempted_at != nil
    end

    test "returns the error (no stamp) on a transient failure, so the worker retries" do
      track = insert(:track, status: :present)
      expect(LoudnessMock, :measure, fn _path -> {:error, :enoent} end)

      assert {:error, :enoent} = Loudness.measure_track(track)
      assert Beatgrid.Repo.get(Track, track.id).loudness_attempted_at == nil
    end
  end

  describe "apply_gain/1" do
    @tag :tmp_dir
    test "backs up the original before applying gain and records the backup path", %{
      tmp_dir: root
    } do
      rel_path = "_Inbox/loud.mp3"
      write_library_file(root, rel_path, "original-audio")

      track =
        insert(:track,
          status: :present,
          rel_path: rel_path,
          loudness_lufs: -11.0,
          true_peak_dbtp: -0.2,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      expect(GainApplierMock, :apply, fn path, gain ->
        assert String.ends_with?(path, "_Inbox/loud.mp3")
        assert gain == -3.0
        File.write!(path, "gain-applied-audio")
        :ok
      end)

      expect(LoudnessMock, :measure, fn path ->
        assert String.ends_with?(path, "_Inbox/loud.mp3")
        {:ok, %{lufs: -14.0, true_peak: -3.2, lra: 5.0}}
      end)

      assert {:ok, updated} = Loudness.apply_gain(track)
      assert updated.loudness_lufs == -14.0
      assert updated.true_peak_dbtp == -3.2
      assert updated.original_loudness_lufs == -11.0
      assert updated.original_true_peak_dbtp == -0.2
      assert updated.original_loudness_measured_at == ~U[2026-01-01 00:00:00Z]
      assert updated.loudness_measurement_origin == :post_gain
      assert updated.gain_applied_db == -3.0
      assert updated.gain_applied_at != nil
      assert File.read!(Path.join(root, rel_path)) == "gain-applied-audio"

      assert [op] = Operations.list_by(track_id: track.id, kind: :gain)
      assert op.from == "-3.0"
      assert op.to =~ "_Backups/Gain/#{track.id}/"
      assert op.to =~ "/_Inbox/loud.mp3"
      assert File.read!(Path.join(root, op.to)) == "original-audio"
      assert op.status == :applied
    end

    test "marks tracks inside tolerance without touching the file" do
      track =
        insert(:track,
          status: :present,
          loudness_lufs: -14.5,
          true_peak_dbtp: -6.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      expect(GainApplierMock, :apply, 0, fn _path, _gain -> :ok end)
      expect(LoudnessMock, :measure, 0, fn _path -> :ok end)

      assert {:ok, updated} = Loudness.apply_gain(track)
      assert updated.gain_applied_db == 0.0
      assert updated.gain_applied_at != nil
      assert Operations.list_by(track_id: track.id, kind: :gain) == []
    end

    @tag :tmp_dir
    test "does not mark the track when the adapter fails", %{tmp_dir: root} do
      rel_path = "_Inbox/failing.mp3"
      write_library_file(root, rel_path, "original-audio")

      track =
        insert(:track,
          status: :present,
          rel_path: rel_path,
          loudness_lufs: -20.0,
          true_peak_dbtp: -8.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      expect(GainApplierMock, :apply, fn _path, 6.0 -> {:error, :failed} end)
      expect(LoudnessMock, :measure, 0, fn _path -> :ok end)

      assert {:error, :failed} = Loudness.apply_gain(track)
      reloaded = Beatgrid.Repo.get!(Track, track.id)
      assert reloaded.gain_applied_db == nil
      assert reloaded.gain_applied_at == nil
    end

    @tag :tmp_dir
    test "recorded gain operations restore the original backup through undo_batch/1", %{
      tmp_dir: root
    } do
      rel_path = "_Inbox/quiet.mp3"
      write_library_file(root, rel_path, "original-audio")

      track =
        insert(:track,
          status: :present,
          rel_path: rel_path,
          loudness_lufs: -20.0,
          true_peak_dbtp: -8.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      expect(GainApplierMock, :apply, fn path, 6.0 ->
        File.write!(path, "gain-applied-audio")
        :ok
      end)

      expect(LoudnessMock, :measure, fn _path ->
        {:ok, %{lufs: -14.0, true_peak: -2.0, lra: 4.0}}
      end)

      assert {:ok, applied} = Loudness.apply_gain(track)
      assert applied.gain_applied_at != nil
      assert [op] = Operations.list_by(track_id: track.id, kind: :gain)
      assert File.read!(Path.join(root, rel_path)) == "gain-applied-audio"

      expect(LoudnessMock, :measure, fn path ->
        assert File.read!(path) == "original-audio"
        {:ok, %{lufs: -20.0, true_peak: -8.0, lra: 4.0}}
      end)

      assert {:ok, %{undone: 1, failed: 0}} = Operations.undo_batch(op.batch_id)
      undone = Beatgrid.Repo.get!(Track, track.id)
      assert undone.gain_applied_db == nil
      assert undone.gain_applied_at == nil
      assert undone.loudness_measurement_origin == :restore_backup
      assert undone.original_loudness_lufs == -20.0
      assert undone.original_true_peak_dbtp == -8.0
      assert File.read!(Path.join(root, rel_path)) == "original-audio"
      assert Operations.count(batch_id: op.batch_id, status: :undone) == 1
    end
  end

  describe "progress + enqueue_pending (by attempted, so unmeasurable files don't stall it)" do
    test "counts attempted vs total and enqueues only not-yet-attempted present tracks" do
      _attempted =
        insert(:track,
          status: :present,
          loudness_lufs: -14.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      pending = insert(:track, status: :present, loudness_attempted_at: nil)
      _missing = insert(:track, status: :missing, loudness_attempted_at: nil)

      assert Loudness.progress() == %{measured: 1, total: 2}

      assert {:ok, 1} = Loudness.enqueue_pending()
      assert_enqueued(worker: LoudnessWorker, args: %{track_id: pending.id})
    end
  end

  describe "enqueue_apply_pending/0" do
    test "enqueues a gain-apply worker for each eligible track" do
      eligible =
        insert(:track,
          status: :present,
          loudness_lufs: -20.0,
          true_peak_dbtp: -8.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      _inside_tolerance =
        insert(:track,
          status: :present,
          loudness_lufs: -14.5,
          true_peak_dbtp: -6.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      assert {:ok, 1, batch_id} = Loudness.enqueue_apply_pending()
      assert_enqueued(worker: GainApplyWorker, args: %{track_id: eligible.id, batch_id: batch_id})
    end
  end

  describe "LoudnessWorker.perform/1" do
    test "measures + stores; cancels for a missing track id" do
      track = insert(:track, status: :present)
      expect(LoudnessMock, :measure, fn _ -> {:ok, %{lufs: -10.0, true_peak: -1.0, lra: 4.0}} end)

      assert :ok = LoudnessWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})
      assert Beatgrid.Repo.get(Track, track.id).loudness_lufs == -10.0

      assert {:cancel, :track_not_found} =
               LoudnessWorker.perform(%Oban.Job{args: %{"track_id" => Ecto.UUID.generate()}})
    end
  end

  describe "GainApplyWorker.perform/1" do
    @tag :tmp_dir
    test "applies gain and cancels for a missing track id", %{tmp_dir: root} do
      rel_path = "_Inbox/worker.mp3"
      write_library_file(root, rel_path, "original-audio")

      track =
        insert(:track,
          status: :present,
          rel_path: rel_path,
          loudness_lufs: -20.0,
          true_peak_dbtp: -8.0,
          loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
        )

      expect(GainApplierMock, :apply, fn _path, 6.0 -> :ok end)

      expect(LoudnessMock, :measure, fn _path ->
        {:ok, %{lufs: -14.0, true_peak: -2.0, lra: 4.0}}
      end)

      assert :ok = GainApplyWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})
      assert Beatgrid.Repo.get!(Track, track.id).gain_applied_db == 6.0

      assert {:cancel, :track_not_found} =
               GainApplyWorker.perform(%Oban.Job{args: %{"track_id" => Ecto.UUID.generate()}})
    end
  end

  defp write_library_file(root, rel_path, contents) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
