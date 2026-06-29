defmodule Beatgrid.Workers.MixRecognizeWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true
  import Beatgrid.Factory
  import Mox
  setup :verify_on_exit!
  setup :set_mox_global
  alias Beatgrid.Library.Normalize
  alias Beatgrid.Workers.MixRecognizeWorker

  setup do
    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: "tok")
    on_exit(fn -> Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: nil) end)
    :ok
  end

  test "fills unnamed segments (:fingerprint) + re-matches; skips named" do
    track = insert(:track, status: :present, tag_artist: "Falamansa", tag_title: "Xote",
      norm_artist: Normalize.normalize("Falamansa"), norm_title: Normalize.normalize("Xote"))
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, end_ms: 10_000, artist: "Já", title: "Tem")
    unnamed = insert(:mix_segment, mix: mix, position: 1, start_ms: 10_000, end_ms: 20_000, artist: nil, title: nil)

    expect(Beatgrid.Recognition.Mock, :identify, fn "/tmp/_Mixes/x.mp3", 10_000, 20_000 ->
      {:ok, %{artist: "Falamansa", title: "Xote"}}
    end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
    seg = Beatgrid.Repo.get(Beatgrid.Mixes.Segment, unnamed.id)
    assert seg.artist == "Falamansa" and seg.name_source == :fingerprint
    assert seg.matched_track_id == track.id
  end

  test "no token -> :ok without calling the recognizer" do
    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: nil)
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, end_ms: 10_000, artist: nil, title: nil)
    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
  end
end
