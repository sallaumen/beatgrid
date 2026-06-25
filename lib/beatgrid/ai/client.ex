defmodule Beatgrid.AI.Client do
  @moduledoc """
  Port for an LLM that returns structured (JSON-schema-constrained) output. The
  real adapter is `Beatgrid.AI.ClaudeCli` (the `claude` CLI, Max plan); tests use
  `Beatgrid.AI.Mock`. `complete/3` returns the parsed JSON object.
  """

  @callback complete(prompt :: String.t(), schema :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
