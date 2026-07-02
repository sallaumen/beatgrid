defmodule Beatgrid.Audio.LibrosaCli do
  @moduledoc """
  Audio-analysis adapter backed by a small `librosa` Python script
  (`priv/scripts/analyze.py`). Shells out with `System.cmd` and parses the JSON
  `{bpm, key, mode}` it prints. Requires `librosa` installed for the `python3` on
  `PATH` (configurable via `:python`).
  """
  @behaviour Beatgrid.Audio.Analyzer

  alias Beatgrid.Cli

  # Librosa loads + analyzes the whole file; a few minutes covers even long tracks.
  @default_timeout_ms 300_000

  # Pin each librosa process to a single thread. numpy/numba/BLAS otherwise spawn a
  # thread per core PER process, so running several analyses at once oversubscribes
  # the CPU (12 cores × N processes) and throughput stutters. One thread per process
  # lets Oban's queue concurrency provide clean, steady parallelism instead.
  # `VECLIB_MAXIMUM_THREADS` covers macOS's Accelerate/vecLib backend.
  @thread_env [
    {"OMP_NUM_THREADS", "1"},
    {"OPENBLAS_NUM_THREADS", "1"},
    {"MKL_NUM_THREADS", "1"},
    {"NUMEXPR_NUM_THREADS", "1"},
    {"NUMBA_NUM_THREADS", "1"},
    {"VECLIB_MAXIMUM_THREADS", "1"}
  ]

  @impl Beatgrid.Audio.Analyzer
  def analyze(path) do
    cmd = fn ->
      System.cmd(python(), [script(), path], stderr_to_stdout: false, env: @thread_env)
    end

    case Cli.run(cmd, timeout()) do
      {:ok, {output, 0}} -> parse(output)
      {:ok, {output, code}} -> {:error, {:analyze_exit, code, String.slice(output, 0, 500)}}
      {:error, :timeout} -> {:error, :timeout}
      {:error, {:exit, reason}} -> {:error, {:analyze_exception, inspect(reason)}}
    end
  rescue
    error -> {:error, {:analyze_exception, Exception.message(error)}}
  end

  @doc "Parses the analyzer script's JSON line into the typed result."
  @spec parse(String.t()) ::
          {:ok, %{bpm: float(), key: integer(), mode: integer()}} | {:error, term()}
  def parse(output) do
    case Jason.decode(output) do
      {:ok, %{"bpm" => bpm, "key" => key, "mode" => mode}}
      when is_number(bpm) and is_integer(key) and is_integer(mode) ->
        {:ok, %{bpm: bpm / 1, key: key, mode: mode}}

      {:ok, other} ->
        {:error, {:unexpected_output, other}}

      {:error, _} ->
        {:error, {:invalid_json, String.slice(output, 0, 200)}}
    end
  end

  defp python, do: config()[:python] || "python3"
  defp timeout, do: config()[:timeout_ms] || @default_timeout_ms
  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
  defp script, do: Application.app_dir(:beatgrid, "priv/scripts/analyze.py")
end
