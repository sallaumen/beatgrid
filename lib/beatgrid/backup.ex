defmodule Beatgrid.Backup do
  @moduledoc """
  Database backups of the CURATION — sets, manual markers, ratings, dedup
  decisions and recorte provenance all live only in Postgres, so one docker
  mishap would erase months of work. Dumps land in `library_root/_Backups/DB`
  (the folder the DJ already keeps safe), pruned to the newest `@keep`.

  Restoring intentionally stays a guided MANUAL step (`restore_command/1`):
  dropping the live database from inside the running app is a footgun.
  """
  require Logger

  alias Beatgrid.Library

  @dumper Application.compile_env(
            :beatgrid,
            [Beatgrid.Backup.Dumper, :adapter],
            Beatgrid.Backup.DumperCli
          )

  @keep 14
  @topic "backup"

  @doc "Subscribe to backup completions (`{:backup_tick}` — contract: `Beatgrid.Events`)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Broadcast a tick so the Painel refreshes the last-backup card."
  @spec broadcast_tick() :: :ok
  def broadcast_tick, do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:backup_tick})

  @doc """
  Dumps the database into a timestamped file (tmp + rename, so a killed dump
  never leaves a half-written "backup") and prunes to the newest #{@keep}.
  """
  @spec dump() :: {:ok, String.t()} | {:error, term()}
  def dump do
    File.mkdir_p!(dir())
    name = "beatgrid-#{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d-%H%M%S")}.dump"
    dest = Path.join(dir(), name)
    tmp = dest <> ".dumping"

    case @dumper.dump(repo_config(), tmp) do
      :ok ->
        File.rename!(tmp, dest)
        prune()
        broadcast_tick()
        {:ok, dest}

      {:error, reason} ->
        File.rm(tmp)
        Logger.error("backup: pg_dump falhou: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Newest-first dump files as `%{path, name, size, at}`."
  @spec list() :: [map()]
  def list do
    dir()
    |> Path.join("beatgrid-*.dump")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      stat = File.stat!(path, time: :posix)

      %{
        path: path,
        name: Path.basename(path),
        size: stat.size,
        at: DateTime.from_unix!(stat.mtime)
      }
    end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  @doc "The newest dump (nil when none exists yet)."
  @spec latest() :: map() | nil
  def latest, do: List.first(list())

  @doc "The exact command to restore a dump — shown in the UI, run by a human."
  @spec restore_command(map()) :: String.t()
  def restore_command(%{path: path}) do
    cfg = repo_config()

    "PGPASSWORD=#{cfg[:password]} pg_restore -h #{cfg[:hostname]} -p #{cfg[:port]} " <>
      "-U #{cfg[:username]} -d #{cfg[:database]} --clean --if-exists \"#{path}\""
  end

  defp prune do
    list()
    |> Enum.drop(@keep)
    |> Enum.each(&File.rm(&1.path))
  end

  defp dir, do: Path.join([Library.library_root(), "_Backups", "DB"])

  defp repo_config, do: Application.get_env(:beatgrid, Beatgrid.Repo)
end
