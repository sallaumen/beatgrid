defmodule Mix.Tasks.Beatgrid.Resolve do
  @shortdoc "Enrich tracks with Soundcharts metadata (BPM, key/Camelot, energy)"
  @moduledoc """
  Resolves unresolved tracks against Soundcharts and caches the result. Budget-
  guarded: it stops before the safety floor and never re-fetches a cached song.
  Each track costs ~2 API calls (search + metadata).

      $ mix beatgrid.resolve                 # up to 25 tracks (asks before spending)
      $ mix beatgrid.resolve --limit 100
      $ mix beatgrid.resolve --limit 400 --yes
  """
  use Mix.Task

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Soundcharts

  @requirements ["app.start"]
  @default_limit 25

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [limit: :integer, yes: :boolean])
    limit = opts[:limit] || @default_limit
    shell = Mix.shell()

    budget = Soundcharts.budget()
    unresolved = Tracks.count(status: :present, resolved: false)
    planned = min(limit, unresolved)

    shell.info(
      "Budget: #{budget.remaining} remaining " <>
        "(used #{budget.used}/#{budget.cap}, header #{inspect(budget.header_remaining)})"
    )

    shell.info(
      "Unresolved present tracks: #{unresolved}; " <>
        "will attempt up to #{planned} (≈ #{planned * 2} API calls)."
    )

    cond do
      planned == 0 -> shell.info("Nothing to resolve. ✔")
      confirmed?(shell, opts, planned) -> run_batch(shell, limit)
      true -> shell.info("Aborted.")
    end

    :ok
  end

  defp confirmed?(shell, opts, planned),
    do: opts[:yes] || shell.yes?("Spend quota to resolve #{planned} tracks?")

  defp run_batch(shell, limit) do
    summary = Soundcharts.resolve_unresolved(limit)
    budget = Soundcharts.budget()

    shell.info("\n== Done ==")
    shell.info("  resolved: #{summary.resolved}")
    shell.info("  no match: #{summary.no_match}")
    shell.info("  errors:   #{summary.errors}")
    if summary.stopped, do: shell.info("  ⚠ stopped early — budget floor reached")
    shell.info("  budget now: #{budget.remaining} remaining (used #{budget.used}/#{budget.cap})")
  end
end
