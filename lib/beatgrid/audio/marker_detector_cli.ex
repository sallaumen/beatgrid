defmodule Beatgrid.Audio.MarkerDetectorCli do
  @moduledoc """
  Marker-detection adapter backed by `priv/scripts/marker_analyze.py` (librosa).
  Shells out with `System.cmd` and parses the final `{"markers": {...}}` JSON line
  (progress lines are ignored). Requires `librosa` for the `python3` on `PATH`
  (overridable via `:python`). Thread-pinned like the analyzer (see comment below).
  """
  @behaviour Beatgrid.Audio.MarkerDetector

  alias Beatgrid.Cli

  # Librosa loads + analyzes the whole file; a few minutes covers even long tracks.
  @default_timeout_ms 300_000

  # One thread per process: numpy/numba/BLAS otherwise spawn a thread per core per
  # process, so concurrent analyses oversubscribe the CPU. Oban queue concurrency
  # then provides clean parallelism. VECLIB covers macOS Accelerate.
  @thread_env [
    {"OMP_NUM_THREADS", "1"},
    {"OPENBLAS_NUM_THREADS", "1"},
    {"MKL_NUM_THREADS", "1"},
    {"NUMEXPR_NUM_THREADS", "1"},
    {"NUMBA_NUM_THREADS", "1"},
    {"VECLIB_MAXIMUM_THREADS", "1"}
  ]

  @impl Beatgrid.Audio.MarkerDetector
  def detect(path) do
    cmd = fn ->
      System.cmd(python(), [script(), path], stderr_to_stdout: false, env: @thread_env)
    end

    case Cli.run(cmd, timeout()) do
      {:ok, {output, 0}} -> parse(output)
      {:ok, {output, code}} -> {:error, {:marker_detect_exit, code, String.slice(output, 0, 500)}}
      {:error, :timeout} -> {:error, :timeout}
      {:error, {:exit, reason}} -> {:error, {:marker_detect_exception, inspect(reason)}}
    end
  rescue
    error -> {:error, {:marker_detect_exception, Exception.message(error)}}
  end

  @doc "Parses the script's output, taking the last line carrying a `markers` object."
  @spec parse(String.t()) :: {:ok, Beatgrid.Audio.MarkerDetector.detection()} | {:error, term()}
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value({:error, {:no_markers, String.slice(output, 0, 200)}}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"markers" => m}} when is_map(m) -> {:ok, to_detection(m)}
        _other -> nil
      end
    end)
  end

  defp to_detection(m) do
    %{
      intro_ms: m["intro_ms"],
      outro_ms: m["outro_ms"],
      beat_ms: m["beat_ms"],
      bpm: m["bpm"],
      sections: m["sections"] || []
    }
  end

  defp python, do: config()[:python] || "python3"
  defp timeout, do: config()[:timeout_ms] || @default_timeout_ms
  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
  defp script, do: Application.app_dir(:beatgrid, "priv/scripts/marker_analyze.py")
end
