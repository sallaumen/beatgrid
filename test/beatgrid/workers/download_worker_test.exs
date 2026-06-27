defmodule Beatgrid.Workers.DownloadWorkerTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Workers.DownloadWorker
  alias Beatgrid.YouTube.DownloaderMock

  defp job(opts \\ []) do
    %Oban.Job{
      args: %{"url" => "https://youtu.be/x"},
      attempt: Keyword.get(opts, :attempt, 1),
      errors: Keyword.get(opts, :errors, [])
    }
  end

  defp stub_download(result), do: stub(DownloaderMock, :download, fn _url, _dest -> result end)

  defp err(message), do: [%{"attempt" => 1, "error" => message}]

  @rate_limited {:yt_dlp_exit, 1,
                 "WARNING: [youtube] Unable to download webpage: HTTP Error 429: Too Many Requests\n" <>
                   "ERROR: [youtube] x: Video unavailable. This video is not available\n"}

  @unavailable {:yt_dlp_exit, 1,
                "ERROR: [youtube] x: Video unavailable. This video is not available\n"}

  test "a 429 is retried even when yt-dlp also reports the video unavailable" do
    stub_download({:error, @rate_limited})
    assert {:error, @rate_limited} = DownloadWorker.perform(job())
  end

  test "a genuinely unavailable video (no 429) is cancelled, not retried" do
    stub_download({:error, @unavailable})
    assert {:cancel, @unavailable} = DownloadWorker.perform(job())
  end

  test "other transient errors are retried" do
    stub_download({:error, :timeout})
    assert {:error, :timeout} = DownloadWorker.perform(job())
  end

  test "backoff waits 30s+ after a 429 and escalates with the attempt" do
    assert DownloadWorker.backoff(
             job(attempt: 1, errors: err("HTTP Error 429: Too Many Requests"))
           ) == 30

    assert DownloadWorker.backoff(job(attempt: 3, errors: err("HTTP Error 429"))) == 90
  end

  test "backoff falls back to the Oban default for non-429 errors" do
    value = DownloadWorker.backoff(job(attempt: 1, errors: err("** (RuntimeError) :timeout")))
    assert is_integer(value) and value < 30
  end
end
