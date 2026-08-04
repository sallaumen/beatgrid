defmodule Beatgrid.Preflight do
  @moduledoc """
  Boot-time check that Postgres is actually reachable.

  Without it, a sleeping database turns startup into a wall of Oban supervisor
  crashes (notifier/peer/producer timeouts) that says nothing about the real
  cause. This probes the socket first and, when it is down, prints one short
  instruction instead — the DB is where the whole library lives, so there is
  no useful degraded mode to fall back to.
  """

  require Logger

  @probe_timeout_ms 3_000

  @doc """
  Returns `:ok` when the configured database answers, `{:error, reason}` when
  it does not. Never raises — a failed probe is an expected state.
  """
  @spec database() :: :ok | {:error, term()}
  def database do
    config =
      :beatgrid
      |> Application.fetch_env!(Beatgrid.Repo)
      |> Keyword.take([:username, :password, :hostname, :port, :database, :socket_dir])
      |> Keyword.put(:timeout, @probe_timeout_ms)
      |> Keyword.put(:connect_timeout, @probe_timeout_ms)

    with {:ok, conn} <- start_probe(config) do
      result = query(conn, config)
      GenServer.stop(conn, :normal, @probe_timeout_ms)
      result
    end
  end

  defp start_probe(config) do
    case Postgrex.start_link(config) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp query(conn, config) do
    case Postgrex.query(conn, "SELECT 1", [], timeout: @probe_timeout_ms) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, {:timeout, config[:hostname]}}
  end

  @doc "Logs the actionable message for a database that did not answer."
  @spec log_unavailable(term()) :: :ok
  def log_unavailable(reason) do
    config = Application.fetch_env!(:beatgrid, Beatgrid.Repo)

    Logger.error("""

    ┌─ Banco de dados fora do ar ────────────────────────────────────────┐
      O beatgrid não conseguiu falar com o Postgres em \
    #{config[:hostname]}:#{config[:port]} (banco "#{config[:database]}").
      Toda a biblioteca (faixas, sets, marcadores) vive nele — sem ele o
      app não sobe.

      Ligue o banco e tente de novo:

          docker compose up -d

      Se o Docker Desktop estiver travado (container preso em
      "Restarting"), feche-o e abra de novo antes do comando acima.
      Seus dados ficam no volume beatgrid_pg e não se perdem nisso.
    └────────────────────────────────────────────────────────────────────┘

    Detalhe técnico: #{inspect(reason)}
    """)

    :ok
  end
end
