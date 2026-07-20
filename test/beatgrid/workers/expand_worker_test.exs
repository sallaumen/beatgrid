defmodule Beatgrid.Workers.ExpandWorkerTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Workers.ExpandWorker
  alias Beatgrid.YouTube.DownloaderMock

  defp job, do: %Oban.Job{args: %{"url" => "https://youtu.be/playlist"}}

  test "an empty expansion is permanent — cancel, never retry" do
    stub(DownloaderMock, :list_entries, fn _url -> {:ok, []} end)

    assert {:cancel, :no_entries} = ExpandWorker.perform(job())
  end

  test "a transient failure keeps the retryable error shape" do
    stub(DownloaderMock, :list_entries, fn _url ->
      {:error, Beatgrid.YtDlpError.from_exit(1, "boom")}
    end)

    assert {:error, %Beatgrid.Error{code: :yt_dlp_exit}} = ExpandWorker.perform(job())
  end
end
