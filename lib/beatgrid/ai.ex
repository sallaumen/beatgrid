defmodule Beatgrid.AI do
  @moduledoc """
  Shared AI plumbing. The client port lives in `Beatgrid.AI.Client`; the use-case AI lives
  in `Beatgrid.Library.MetadataAI`, `Beatgrid.Organization.ClassificationAI`, and
  `Beatgrid.Repertoire.RecommendationAI`. This module just wraps the client with the model
  default so those call one entry point.
  """
  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.AI.Client, :adapter],
             Beatgrid.AI.ClaudeCli
           )

  @doc "Calls the AI client with the model default applied. The single AI entry point."
  @spec complete(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(prompt, schema, opts \\ []) do
    @adapter.complete(prompt, schema, Keyword.put_new(opts, :model, model()))
  end

  @doc "Configured AI model (default \"sonnet\")."
  def model, do: config(:model, "sonnet")

  @doc "Configured classification batch size (default 15)."
  def batch_size, do: config(:batch_size, 15)

  defp config(key, default),
    do: :beatgrid |> Application.get_env(Beatgrid.AI, []) |> Keyword.get(key, default)
end
