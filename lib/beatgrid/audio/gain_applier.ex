defmodule Beatgrid.Audio.GainApplier do
  @moduledoc """
  Port for applying a gain delta directly to an audio file on disk.
  """

  @callback apply(path :: String.t(), gain_db :: float()) :: :ok | {:error, term()}
end
