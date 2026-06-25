defmodule Beatgrid.Tagging.Writer do
  @moduledoc "Port contract for writing ID3 tags to an audio file on disk."

  @callback write_genre(path :: String.t(), genre :: String.t()) :: :ok | {:error, term()}
end
