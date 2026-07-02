defmodule Beatgrid.AI.ClaudeCli do
  @moduledoc """
  AI adapter backed by the `claude` CLI (Max plan, ToS-compliant). Runs
  `claude -p <prompt> --output-format json --json-schema <schema>` and returns the
  `structured_output` object from the result envelope.

  Two hardening details so a CLI call can never hang the caller (e.g. the Painel's
  "Lacunas" async): stdin is redirected from `/dev/null` (the CLI otherwise blocks
  waiting for piped input when spawned non-interactively from iex/phx.server), and
  the whole call is bounded by `:timeout_ms`, surfacing `{:error, :timeout}` instead
  of an endless spinner.
  """
  @behaviour Beatgrid.AI.Client

  alias Beatgrid.Cli

  @default_timeout_ms 120_000

  @impl Beatgrid.AI.Client
  def complete(prompt, schema, opts \\ []) do
    cli_args = build_args(prompt, schema, opts)

    # Run through `sh` with stdin from /dev/null. `exec "$@"` forwards argv verbatim,
    # so the prompt/schema need no shell quoting and the CLI gets immediate EOF.
    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: false) end, opts)
  end

  @spec build_args(String.t(), map(), keyword()) :: [String.t()]
  def build_args(prompt, schema, opts) do
    ["-p", prompt, "--output-format", "json", "--json-schema", Jason.encode!(schema)] ++
      model_args(opts) ++ add_dir_args(opts) ++ tool_args(opts)
  end

  # Headless runs get NO tools unless the caller allows them explicitly (e.g. the
  # metadata verifier grounds its verdicts with WebSearch).
  defp tool_args(opts) do
    case opts[:allowed_tools] do
      [_ | _] = tools -> ["--allowedTools", Enum.join(tools, ",")]
      _ -> []
    end
  end

  defp add_dir_args(opts) do
    case opts[:add_dir] do
      dirs when is_list(dirs) -> Enum.flat_map(dirs, &["--add-dir", &1])
      _ -> []
    end
  end

  defp run(fun, opts) do
    case Cli.run(fun, timeout(opts)) do
      {:ok, {output, 0}} -> parse_output(output)
      {:ok, {output, code}} -> {:error, {:claude_cli_exit, code, String.slice(output, 0, 500)}}
      {:error, {:exit, reason}} -> {:error, {:claude_cli_exception, inspect(reason)}}
      {:error, :timeout} -> {:error, :timeout}
    end
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

  defp executable, do: config()[:executable] || "claude"

  # Callers with legitimately long generations (repertoire gaps) pass their own
  # :timeout_ms; everything else uses the config/default budget.
  defp timeout(opts), do: opts[:timeout_ms] || config()[:timeout_ms] || @default_timeout_ms

  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
end
