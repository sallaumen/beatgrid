defmodule Beatgrid.Audio do
  @moduledoc """
  Port for reading audio metadata. The concrete adapter is chosen at compile time
  (`Beatgrid.Audio.Ffprobe` in dev/prod, `Beatgrid.Audio.Mock` in test).
  """
  @behaviour Beatgrid.Audio.Behaviour

  @adapter Application.compile_env!(:beatgrid, [__MODULE__, :adapter])

  @impl true
  defdelegate read_metadata(path), to: @adapter
end
