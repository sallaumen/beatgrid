defmodule Beatgrid.Video.FrameSampler do
  @moduledoc "Port for sampling video frames into a labeled montage for OCR."
  @callback resolve_stream(url :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback sample_grid(stream_url :: String.t(), opts :: %{tiles: [integer()], dest: String.t()}) ::
              {:ok, String.t()} | {:error, term()}
end
