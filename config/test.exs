import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :beatgrid, Beatgrid.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5434,
  database: "beatgrid_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :beatgrid, BeatgridWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NZq4DdfH8oqgru5l0I4VVbZF3ZsWpU2lritVfYjjagGOm4m0ZdRPjiQmhJCF9bNQ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban: don't run jobs automatically in tests — drive them with perform_job/2.
config :beatgrid, Oban, testing: :manual

# Integration ports → Mox mocks (see test/support/mocks.ex).
config :beatgrid, Beatgrid.Audio, adapter: Beatgrid.Audio.Mock
config :beatgrid, Beatgrid.Soundcharts.Client, adapter: Beatgrid.Soundcharts.Mock
config :beatgrid, Beatgrid.AI.Client, adapter: Beatgrid.AI.Mock
config :beatgrid, Beatgrid.Tagging.Writer, adapter: Beatgrid.Tagging.Mock
config :beatgrid, Beatgrid.Audio.Analyzer, adapter: Beatgrid.Audio.AnalyzerMock
config :beatgrid, Beatgrid.Audio.Loudness, adapter: Beatgrid.Audio.LoudnessMock
config :beatgrid, Beatgrid.YouTube.Downloader, adapter: Beatgrid.YouTube.DownloaderMock
config :beatgrid, Beatgrid.Mixes.Source, adapter: Beatgrid.Mixes.SourceMock

# The Http adapter, when exercised directly, routes through Req.Test instead of
# the network (see test/beatgrid/soundcharts/http_test.exs). A dummy account gives
# it credentials so the adapter doesn't refuse with :no_credentials (the Mock used
# elsewhere ignores these values).
config :beatgrid, Beatgrid.Soundcharts.Http,
  req_options: [plug: {Req.Test, Beatgrid.Soundcharts.Http}],
  accounts: [%{id: "1", app_id: "test-app-id", api_key: "test-api-key"}]
