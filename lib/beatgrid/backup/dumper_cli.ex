defmodule Beatgrid.Backup.DumperCli do
  @moduledoc """
  `pg_dump`-backed dumper (custom format `-Fc`: compressed, restorable with
  `pg_restore --clean`). The password travels via PGPASSWORD, never argv.
  """
  @behaviour Beatgrid.Backup.Dumper

  alias Beatgrid.Cli

  @timeout_ms 120_000

  @impl Beatgrid.Backup.Dumper
  def dump(cfg, dest) do
    args = [
      "-Fc",
      "-h",
      to_string(cfg[:hostname]),
      "-p",
      to_string(cfg[:port] || 5432),
      "-U",
      to_string(cfg[:username]),
      "-f",
      dest,
      to_string(cfg[:database])
    ]

    env = [{"PGPASSWORD", to_string(cfg[:password])}]
    run = fn -> System.cmd("pg_dump", args, env: env, stderr_to_stdout: true) end

    case Cli.run(run, @timeout_ms) do
      {:ok, {_out, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:pg_dump_exit, code, String.slice(out, 0, 300)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
