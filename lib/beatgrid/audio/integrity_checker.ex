defmodule Beatgrid.Audio.IntegrityChecker do
  @moduledoc """
  Behaviour for checking whether an audio file is playable end to end. The
  console freezing mid-track traced back to half-written files from the old
  in-place gain writer — this is the detector that finds them before a set does.
  """

  @doc """
  Fully decodes the file. `:ok` when every frame decodes; `{:error, :enoent}`
  when the file is gone from disk; `{:error, {:corrupt, message}}` when the
  decoder chokes partway.
  """
  @callback check(path :: String.t()) :: :ok | {:error, :enoent | {:corrupt, String.t()}}
end
