# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :beatgrid,
  ecto_repos: [Beatgrid.Repo],
  generators: [timestamp_type: :utc_datetime]

# Repo-wide Ecto defaults: UTC timestamps everywhere + advisory migration lock.
config :beatgrid, Beatgrid.Repo,
  migration_timestamps: [type: :utc_datetime],
  migration_lock: :pg_advisory_lock

# Default library root — the on-disk source of truth. Overridable at runtime via
# the settings table (see Beatgrid.Settings).
config :beatgrid, :library_root, Path.expand("~/Music/DJ")

# Background jobs (Oban). Queues sized for a single-user local app; the
# `soundcharts` queue is serialized (local_limit 1) to respect the API budget.
config :beatgrid, Oban,
  repo: Beatgrid.Repo,
  queues: [default: 10, scan: 2, soundcharts: 1, ai: 2],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

# Integration ports (ports & adapters). Tests override these with Mox mocks.
config :beatgrid, Beatgrid.Audio, adapter: Beatgrid.Audio.Ffprobe

# Configure the endpoint
config :beatgrid, BeatgridWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BeatgridWeb.ErrorHTML, json: BeatgridWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Beatgrid.PubSub,
  live_view: [signing_salt: "xcj3TIqm"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  beatgrid: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  beatgrid: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
