defmodule Beatgrid.Video.FrameSampler do
  @moduledoc "Port for sampling video frames (one sequential pass) and tiling them into montages for OCR."
  @callback resolve_stream(url :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "One sequential pass: extract a cropped lower-third frame every interval_ms into dir. Returns sorted frame paths (frame k, 0-indexed, is at k*interval_ms)."
  @callback extract_frames(stream_url :: String.t(), opts :: %{interval_ms: integer(), dir: String.t()}) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc "Tile already-cropped local frames into one montage image (reading order)."
  @callback montage(frame_paths :: [String.t()], dest :: String.t()) :: {:ok, String.t()} | {:error, term()}
end
