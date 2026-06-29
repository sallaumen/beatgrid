defmodule Beatgrid.Recognition do
  @moduledoc "Port for acoustic track recognition (Shazam-style) of a segment window."
  @callback identify(audio_path :: String.t(), start_ms :: integer(), end_ms :: integer()) ::
              {:ok, %{artist: String.t(), title: String.t()}} | {:ok, :no_match} | {:error, term()}
end
