defmodule Beatgrid.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Structured logs for every Oban job (start/stop/exception, with worker, queue,
    # duration and the full error + stacktrace on failure). Without this, failed or
    # crashed background jobs are invisible. Idempotent — safe across hot restarts.
    Oban.Telemetry.attach_default_logger(
      level: :info,
      events: ~w(job notifier peer queue stager)a
    )

    children = [
      BeatgridWeb.Telemetry,
      Beatgrid.Repo,
      {DNSCluster, query: Application.get_env(:beatgrid, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Beatgrid.PubSub},
      Beatgrid.Playback.NowPlaying,
      Beatgrid.Playback.QuietMode,
      {Task.Supervisor, name: Beatgrid.TaskSupervisor},
      {Oban, Application.fetch_env!(:beatgrid, Oban)},
      # Start to serve requests, typically the last entry
      BeatgridWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Beatgrid.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeatgridWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
