defmodule Beatgrid.AI.ClaudeCli do
  @moduledoc """
  AI adapter backed by the `claude` CLI (Max plan, ToS-compliant). Runs
  `claude -p <prompt> --output-format json --json-schema <schema>` and returns the
  `structured_output` object from the result envelope.
  """
  @behaviour Beatgrid.AI.Client

  @impl Beatgrid.AI.Client
  def complete(prompt, schema, opts \\ []) do
    args =
      ["-p", prompt, "--output-format", "json", "--json-schema", Jason.encode!(schema)] ++
        model_args(opts)

    case System.cmd(executable(), args, stderr_to_stdout: false) do
      {output, 0} -> parse_output(output)
      {output, code} -> {:error, {:claude_cli_exit, code, String.slice(output, 0, 500)}}
    end
  rescue
    error -> {:error, {:claude_cli_exception, Exception.message(error)}}
  end

  @doc """
  Parses the `claude --output-format json` envelope, returning its
  `structured_output` object (the schema-constrained result).
  """
  @spec parse_output(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_output(output) do
    case Jason.decode(output) do
      {:ok, %{"is_error" => true} = env} -> {:error, {:claude_error, env["result"]}}
      {:ok, %{"structured_output" => structured}} when is_map(structured) -> {:ok, structured}
      {:ok, env} -> {:error, {:no_structured_output, Map.take(env, ["subtype", "result"])}}
      {:error, _decode_error} -> {:error, {:invalid_json, String.slice(output, 0, 200)}}
    end
  end

  defp model_args(opts) do
    case opts[:model] do
      model when is_binary(model) -> ["--model", model]
      _ -> []
    end
  end

  defp executable, do: Application.get_env(:beatgrid, __MODULE__, [])[:executable] || "claude"
end
