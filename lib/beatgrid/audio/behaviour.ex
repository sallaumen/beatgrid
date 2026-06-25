defmodule Beatgrid.Audio.Behaviour do
  @moduledoc "Port contract for reading audio metadata from a file on disk."

  alias Beatgrid.Audio.Metadata

  @callback read_metadata(path :: String.t()) :: {:ok, Metadata.t()} | {:error, term()}
end
