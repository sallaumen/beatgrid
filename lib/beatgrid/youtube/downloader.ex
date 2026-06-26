defmodule Beatgrid.YouTube.Downloader do
  @moduledoc """
  Port for downloading audio from a YouTube URL. A single URL may be one video or
  a whole playlist, so `download/2` returns a list of items (one per track).
  """
  @type item :: %{path: String.t(), title: String.t(), url: String.t()}

  @callback download(url :: String.t(), dest_dir :: String.t()) ::
              {:ok, [item()]} | {:error, term()}
end
