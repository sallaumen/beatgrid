defmodule Beatgrid.MixesCutTest do
  # async: false — cuts write into an isolated :library_root on disk.
  use Beatgrid.DataCase, async: false, oban: true

  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Mixes
  alias Beatgrid.Repo
  alias Beatgrid.Workers.{AnalyzeWorker, LoudnessWorker, MarkerAnalyzeWorker, MixCutWorker}

  @moduletag :tmp_dir

  setup :verify_on_exit!
  setup :set_mox_global
  setup :isolate_library_root

  setup %{tmp_dir: tmp} do
    audio = Path.join(tmp, "mix-audio.mp3")
    File.write!(audio, "mp3-bytes")
    {:ok, mix: insert(:mix, audio_path: audio)}
  end

  defp cut_attrs(overrides \\ %{}) do
    Map.merge(
      %{start_ms: 43_000, end_ms: 90_000, artist: "Zé", title: "Perdida no Set", folder_key: nil},
      overrides
    )
  end

  describe "request_cut/2 (validation + enqueue)" do
    test "queues a MixCutWorker for a valid range", %{mix: mix} do
      assert {:ok, _job} = Mixes.request_cut(mix, cut_attrs())
      assert_enqueued(worker: MixCutWorker, args: %{mix_id: mix.id, start_ms: 43_000})
    end

    test "rejects nonsense before anything is queued", %{mix: mix} do
      assert {:error, :title_required} = Mixes.request_cut(mix, cut_attrs(%{title: "  "}))
      assert {:error, :invalid_range} = Mixes.request_cut(mix, cut_attrs(%{start_ms: nil}))
      assert {:error, :invalid_range} = Mixes.request_cut(mix, cut_attrs(%{end_ms: 43_000}))
      assert {:error, :too_short} = Mixes.request_cut(mix, cut_attrs(%{end_ms: 44_000}))

      assert {:error, :too_long} =
               Mixes.request_cut(mix, cut_attrs(%{end_ms: 43_000 + 16 * 60 * 1000}))

      refute_enqueued(worker: MixCutWorker)
    end

    test "a mix with purged audio refuses the cut" do
      mix = insert(:mix, audio_path: nil, audio_deleted_at: DateTime.utc_now())
      assert {:error, :no_audio} = Mixes.request_cut(mix, cut_attrs())
    end
  end

  describe "cut_to_track/2 (the worker body)" do
    test "cuts the range, registers the marked track, and queues its analysis", %{mix: mix} do
      Mixes.subscribe()

      expect(Beatgrid.Audio.MixCutterMock, :cut, fn src, dest, opts ->
        assert src == mix.audio_path
        assert opts[:start_ms] == 43_000
        assert opts[:end_ms] == 90_000
        File.write!(dest, "cut-bytes")
        :ok
      end)

      assert {:ok, track} = Mixes.cut_to_track(mix, cut_attrs())

      assert track.rel_path == "_Inbox/Zé - Perdida no Set.mp3"
      assert track.status == :present
      assert track.source_playlist == "recorte"
      assert track.duration_ms == 47_000
      assert track.tag_artist == "Zé"
      assert track.tag_title == "Perdida no Set"
      assert track.raw_tags["recorte_mix_id"] == mix.id
      assert track.raw_tags["recorte_start_ms"] == 43_000

      assert_enqueued(worker: AnalyzeWorker, args: %{track_id: track.id})
      assert_enqueued(worker: LoudnessWorker, args: %{track_id: track.id})
      assert_enqueued(worker: MarkerAnalyzeWorker, args: %{track_id: track.id})
      assert_receive {:mix_progress, %{stage: "cut_done", track_id: _}}
    end

    test "a cut born from a segment matches and names it", %{mix: mix} do
      seg =
        insert(:mix_segment,
          mix: mix,
          position: 0,
          start_ms: 43_000,
          end_ms: 90_000,
          artist: nil,
          title: nil
        )

      expect(Beatgrid.Audio.MixCutterMock, :cut, fn _src, dest, _opts ->
        File.write!(dest, "cut-bytes")
        :ok
      end)

      assert {:ok, track} = Mixes.cut_to_track(mix, cut_attrs(%{segment_id: seg.id}))

      reloaded = Repo.get!(Beatgrid.Mixes.Segment, seg.id)
      assert reloaded.matched_track_id == track.id
      assert reloaded.match_confidence == :high
      assert reloaded.title == "Perdida no Set"
      assert reloaded.artist == "Zé"
      assert reloaded.name_source == :manual
    end

    test "a segment that already has a name keeps it, gaining only the match", %{mix: mix} do
      seg =
        insert(:mix_segment,
          mix: mix,
          position: 0,
          start_ms: 43_000,
          end_ms: 90_000,
          artist: "Original",
          title: "Nome do Tracklist"
        )

      expect(Beatgrid.Audio.MixCutterMock, :cut, fn _src, dest, _opts ->
        File.write!(dest, "cut-bytes")
        :ok
      end)

      assert {:ok, track} = Mixes.cut_to_track(mix, cut_attrs(%{segment_id: seg.id}))

      reloaded = Repo.get!(Beatgrid.Mixes.Segment, seg.id)
      assert reloaded.matched_track_id == track.id
      assert reloaded.title == "Nome do Tracklist"
    end

    test "a name collision bumps the filename instead of overwriting", %{mix: mix} do
      root = Beatgrid.Library.library_root()
      File.mkdir_p!(Path.join(root, "_Inbox"))
      File.write!(Path.join(root, "_Inbox/Zé - Perdida no Set.mp3"), "existing")

      expect(Beatgrid.Audio.MixCutterMock, :cut, fn _src, dest, _opts ->
        File.write!(dest, "cut-bytes")
        :ok
      end)

      assert {:ok, track} = Mixes.cut_to_track(mix, cut_attrs())
      assert track.rel_path == "_Inbox/Zé - Perdida no Set (2).mp3"
    end

    test "a failed cut surfaces the reason and registers nothing", %{mix: mix} do
      expect(Beatgrid.Audio.MixCutterMock, :cut, fn _src, _dest, _opts ->
        {:error, {:cut_exit, 1, "boom"}}
      end)

      assert {:error, {:cut_exit, 1, "boom"}} = Mixes.cut_to_track(mix, cut_attrs())
      assert Tracks.count(status: :present) == 0
    end
  end

  test "the worker cancels when the mix audio vanished", %{mix: mix} do
    File.rm!(mix.audio_path)

    assert {:cancel, :no_audio} =
             perform_job(MixCutWorker, %{
               mix_id: mix.id,
               start_ms: 43_000,
               end_ms: 90_000,
               artist: "",
               title: "X",
               folder_key: nil
             })
  end
end
