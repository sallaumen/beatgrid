defmodule Beatgrid.Mixes.Source do
  @moduledoc "Port for fetching a recorded set (audio file + metadata) from an online source URL."

  @type meta :: %{
          audio_path: String.t(),
          title: String.t() | nil,
          dj: String.t() | nil,
          duration_ms: integer() | nil,
          description: String.t(),
          chapters: [%{start_ms: integer(), title: String.t()}]
        }

  @callback fetch(url :: String.t(), dest_dir :: String.t()) :: {:ok, meta()} | {:error, term()}
end
