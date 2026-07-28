defmodule Beatgrid.Audio.IntegrityCheckerCli do
  @moduledoc """
  Integrity-checker adapter backed by ffmpeg: decodes the whole file to null
  output with `-xerror`, so the first broken frame fails the run with a real
  message instead of being papered over. A track decodes at many times real
  time, so even long files answer in a couple of seconds.
  """
  @behaviour Beatgrid.Audio.IntegrityChecker

  alias Beatgrid.Cli

  @default_timeout_ms 60_000

  @impl Beatgrid.Audio.IntegrityChecker
  def check(path) do
    if File.regular?(path) do
      decode(path)
    else
      {:error, :enoent}
    end
  end

  defp decode(path) do
    cmd = fn ->
      System.cmd(
        "ffmpeg",
        ["-v", "error", "-nostdin", "-xerror", "-i", path, "-f", "null", "-"],
        stderr_to_stdout: true
      )
    end

    case Cli.run(cmd, timeout()) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, _code}} -> {:error, {:corrupt, String.slice(output, 0, 200)}}
      {:error, :timeout} -> {:error, {:corrupt, "decode timeout"}}
      {:error, {:exit, reason}} -> {:error, {:corrupt, inspect(reason)}}
    end
  end

  defp timeout do
    Application.get_env(:beatgrid, __MODULE__, [])[:timeout_ms] || @default_timeout_ms
  end
end
