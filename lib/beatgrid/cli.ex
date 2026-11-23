defmodule Beatgrid.Cli do
  @moduledoc """
  Bounded execution for CLI adapters: runs the command function in a task and
  brutally kills it after `timeout_ms`, so an external binary can never hang its
  caller (an Oban queue slot or a LiveView async). Every adapter that shells out
  wraps its `System.cmd` call in `run/2`.
  """

  @type cmd_result :: {binary(), non_neg_integer()}

  @doc "Prefer the Beatgrid-local yt-dlp installation, then the system executable."
  @spec yt_dlp() :: String.t()
  def yt_dlp do
    private_bin =
      Path.join([:filename.basedir(:user_data, "beatgrid"), "yt-dlp", "bin", "yt-dlp"])

    System.find_executable(private_bin) || "yt-dlp"
  end

  @spec run((-> cmd_result), pos_integer()) ::
          {:ok, cmd_result} | {:error, :timeout} | {:error, {:exit, term()}}
  def run(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end
end
