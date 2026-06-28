defmodule Beatgrid.Workers.MixDownloadWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true

  import Beatgrid.Factory
  import Mox

  setup :verify_on_exit!
  setup :set_mox_global

  alias Beatgrid.Mixes
  alias Beatgrid.Workers.{MixAnalyzeWorker, MixDownloadWorker}

  test "downloads, fills metadata, sets :analyzing, and enqueues MixAnalyzeWorker" do
    mix = insert(:mix, status: :downloading, title: nil, audio_path: nil)

    expect(Beatgrid.Mixes.SourceMock, :fetch, fn _url, _dest ->
      {:ok,
       %{
         audio_path: "/tmp/_Mixes/abc.mp3",
         title: "Live Set",
         dj: "DJ X",
         duration_ms: 3_600_000,
         description: "00:00 A - B"
       }}
    end)

    assert :ok = perform_job(MixDownloadWorker, %{mix_id: mix.id})

    reloaded = Mixes.get_mix(mix.id)
    assert reloaded.status == :analyzing
    assert reloaded.title == "Live Set"
    assert reloaded.audio_path == "/tmp/_Mixes/abc.mp3"
    assert reloaded.duration_ms == 3_600_000
    assert_enqueued(worker: MixAnalyzeWorker, args: %{mix_id: mix.id})
  end

  test "a rate-limit error retries (returns {:error, _})" do
    mix = insert(:mix, status: :downloading)

    expect(Beatgrid.Mixes.SourceMock, :fetch, fn _url, _dest ->
      {:error, {:yt_dlp_exit, 1, "HTTP Error 429: Too Many Requests"}}
    end)

    assert {:error, _} = perform_job(MixDownloadWorker, %{mix_id: mix.id})
  end

  test "a permanent failure cancels and marks the mix failed" do
    mix = insert(:mix, status: :downloading)

    expect(Beatgrid.Mixes.SourceMock, :fetch, fn _url, _dest ->
      {:error, {:yt_dlp_exit, 1, "This track is not available"}}
    end)

    assert {:cancel, _} = perform_job(MixDownloadWorker, %{mix_id: mix.id})
    assert Mixes.get_mix(mix.id).status == :failed
  end
end
