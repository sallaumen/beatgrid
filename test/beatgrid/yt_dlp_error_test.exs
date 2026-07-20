defmodule Beatgrid.YtDlpErrorTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Error
  alias Beatgrid.YtDlpError

  test "a 429 classifies as rate-limited, keeping 429 in the message for the backoff grep" do
    error = YtDlpError.from_exit(1, "HTTP Error 429: Too Many Requests")

    assert %Error{code: :rate_limited} = error
    assert error.message =~ "429"
    assert error.details.exit_code == 1
  end

  test "rate limit wins even when yt-dlp also claims the video is unavailable" do
    out =
      "WARNING: [youtube] Unable to download webpage: HTTP Error 429: Too Many Requests\n" <>
        "ERROR: [youtube] x: Video unavailable. This video is not available\n"

    assert %Error{code: :rate_limited} = YtDlpError.from_exit(1, out)
  end

  test "each curated permanent refusal classifies as unavailable" do
    for phrase <- [
          "Video unavailable",
          "This track is not available",
          "Private video",
          "no longer available",
          "removed by the uploader",
          "account associated with this video has been terminated",
          "Sign in to confirm your age"
        ] do
      assert %Error{code: :video_unavailable} = YtDlpError.from_exit(1, "ERROR: #{phrase}"),
             "expected #{inspect(phrase)} to classify as :video_unavailable"
    end
  end

  test "a temporary unavailability is NOT permanent — generic exit, retried" do
    error = YtDlpError.from_exit(1, "ERROR: This video is temporarily unavailable")

    assert %Error{code: :yt_dlp_exit} = error
    assert error.details.output =~ "temporarily"
  end

  test "anything else is a generic exit carrying code and output" do
    assert %Error{code: :yt_dlp_exit, details: %{exit_code: 127, output: "boom"}} =
             YtDlpError.from_exit(127, "boom")
  end
end
