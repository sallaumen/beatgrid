defmodule Mix.Tasks.Beatgrid.Classify do
  @shortdoc "Re-classify tracks into genre folders with Claude (creates pending suggestions)"
  @moduledoc """
  Classifies present tracks into the 6 genre folders with Claude (via the `claude`
  CLI), in batches, and creates a pending `:claude` move suggestion wherever the AI
  disagrees with the current folder. **Nothing moves on disk** — suggestions await
  review. No Soundcharts quota is used.

      $ mix beatgrid.classify --limit 30        # a sample first (asks before running)
      $ mix beatgrid.classify --yes             # all present tracks
      $ mix beatgrid.classify --batch-size 20 --yes
  """
  use Mix.Task

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Organization.ClassificationAI

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [limit: :integer, batch_size: :integer, yes: :boolean])

    shell = Mix.shell()
    present = Tracks.count(status: :present)
    planned = min(opts[:limit] || present, present)

    shell.info("Present tracks: #{present}; will classify up to #{planned} via Claude.")

    if planned == 0 do
      shell.info("Nothing to classify. ✔")
    else
      if opts[:yes] || shell.yes?("Classify #{planned} tracks with Claude (no disk changes)?") do
        run_batch(shell, Keyword.take(opts, [:limit, :batch_size]))
      else
        shell.info("Aborted.")
      end
    end

    :ok
  end

  defp run_batch(shell, opts) do
    summary = ClassificationAI.reclassify(opts)

    shell.info("\n== Done ==")
    shell.info("  classified: #{summary.classified}")
    shell.info("  suggested moves (AI disagreed): #{summary.suggested}")
    shell.info("  agreed with current folder: #{summary.agreed}")
    shell.info("  errors: #{summary.errors}")
    shell.info("\nReview pending suggestions with: mix beatgrid.suggest (or the future UI)")
  end
end
