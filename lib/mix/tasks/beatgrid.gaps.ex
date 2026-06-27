defmodule Mix.Tasks.Beatgrid.Gaps do
  @shortdoc "Suggest important artists/songs missing from a genre folder (Claude)"
  @moduledoc """
  Asks Claude for canonical artists/songs the library is likely missing for a genre
  folder, given what it already has. Read-only analysis — no Soundcharts quota, no
  disk changes.

      $ mix beatgrid.gaps forro_classico
      $ mix beatgrid.gaps forro_roots --count 15
  """
  use Mix.Task

  alias Beatgrid.Repertoire.RecommendationAI

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [count: :integer])
    shell = Mix.shell()

    case args do
      [folder | _] -> suggest(shell, folder, Keyword.take(opts, [:count]))
      [] -> shell.error("usage: mix beatgrid.gaps <folder_key> [--count N]")
    end

    :ok
  end

  defp suggest(shell, folder, opts) do
    case RecommendationAI.suggest_gaps(folder, opts) do
      {:ok, gaps} ->
        shell.info("Missing classics for #{folder} (#{length(gaps)}):")

        Enum.each(gaps, fn gap ->
          shell.info("  • #{gap.artist} — #{gap.song}  (#{gap.reason})")
        end)

      {:error, reason} ->
        shell.error("Could not suggest gaps: #{inspect(reason)}")
    end
  end
end
