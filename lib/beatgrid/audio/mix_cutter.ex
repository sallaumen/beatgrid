defmodule Beatgrid.Audio.MixCutter do
  @moduledoc """
  Cuts a time range out of a mix's audio file into a standalone tagged MP3 —
  the engine behind "Recortes" (turning a slice of an imported set into a real
  library track when the original song can't be found anywhere).
  """

  @type cut_opts :: [
          start_ms: non_neg_integer(),
          end_ms: pos_integer(),
          artist: String.t(),
          title: String.t()
        ]

  @callback cut(src :: String.t(), dest :: String.t(), opts :: cut_opts()) ::
              :ok | {:error, term()}
end
