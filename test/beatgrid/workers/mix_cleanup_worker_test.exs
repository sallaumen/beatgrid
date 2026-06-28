defmodule Beatgrid.Workers.MixCleanupWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true

  import Beatgrid.Factory

  alias Beatgrid.Library
  alias Beatgrid.Mixes
  alias Beatgrid.Workers.MixCleanupWorker

  test "deletes the audio file under _Mixes and stamps audio_deleted_at" do
    dir = Path.join(Library.library_root(), "_Mixes")
    File.mkdir_p!(dir)
    path = Path.join(dir, "cleanup-test.mp3")
    File.write!(path, "audio")
    mix = insert(:mix, status: :ready, audio_path: path)

    assert :ok = perform_job(MixCleanupWorker, %{mix_id: mix.id})

    refute File.exists?(path)
    reloaded = Mixes.get_mix(mix.id)
    assert reloaded.audio_deleted_at != nil
    assert reloaded.audio_path == nil
  end

  test "is a no-op when the audio is already purged" do
    mix = insert(:mix, status: :ready, audio_path: nil)
    assert :ok = perform_job(MixCleanupWorker, %{mix_id: mix.id})
  end

  test "refuses to delete a path outside _Mixes (fence)" do
    outside = Path.join(System.tmp_dir!(), "not-a-mix.mp3")
    File.write!(outside, "keep me")
    mix = insert(:mix, status: :ready, audio_path: outside)

    assert :ok = perform_job(MixCleanupWorker, %{mix_id: mix.id})
    assert File.exists?(outside)
    File.rm(outside)
  end
end
