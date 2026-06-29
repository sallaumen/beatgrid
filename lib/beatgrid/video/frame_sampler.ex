defmodule Beatgrid.Video.FrameSampler do
  @moduledoc "Port for OCR frame sampling: download a low-res video, extract frames locally, tile into montages."

  @doc "Download a low-res (<=360p) copy of the video into dir; returns the local file path."
  @callback download_video(url :: String.t(), dir :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Extract a cropped lower-third frame every interval_ms from a LOCAL video file into dir. Returns sorted frame paths (frame k, 0-indexed, is at k*interval_ms)."
  @callback extract_frames(video_path :: String.t(), opts :: %{interval_ms: integer(), dir: String.t()}) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc "Tile already-cropped local frames into one montage image (reading order)."
  @callback montage(frame_paths :: [String.t()], dest :: String.t()) :: {:ok, String.t()} | {:error, term()}
end
