defmodule Beatgrid.LoudnessTest do
  use Beatgrid.DataCase, async: false, oban: true

  import Mox
  import Beatgrid.Factory

  alias Beatgrid.Audio.{FfmpegLoudness, LoudnessMock}
  alias Beatgrid.Library.Track
  alias Beatgrid.Loudness
  alias Beatgrid.Workers.LoudnessWorker

  setup :verify_on_exit!

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

  describe "LoudnessWorker.perform/1" do
    test "measures + stores; no-op for a missing track id" do
      track = insert(:track, status: :present)
      expect(LoudnessMock, :measure, fn _ -> {:ok, %{lufs: -10.0, true_peak: -1.0, lra: 4.0}} end)

      assert :ok = LoudnessWorker.perform(%Oban.Job{args: %{"track_id" => track.id}})
      assert Beatgrid.Repo.get(Track, track.id).loudness_lufs == -10.0

      assert :ok = LoudnessWorker.perform(%Oban.Job{args: %{"track_id" => Ecto.UUID.generate()}})
    end
  end
end
