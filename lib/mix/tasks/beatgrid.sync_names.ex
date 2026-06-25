defmodule Mix.Tasks.Beatgrid.SyncNames do
  @shortdoc "Sync file names to the canonical \"Artist - Title\" from Soundcharts"
  @moduledoc """
  Proposes renames for resolved tracks whose file name differs from the canonical
  `"Artist - Title"`. By default it only previews (proposes + prints); pass
  `--yes` to auto-apply the **high-confidence** renames on disk. Medium/low
  matches always stay as pending suggestions for manual review.

      $ mix beatgrid.sync_names          # preview only (no disk changes)
      $ mix beatgrid.sync_names --yes    # also auto-rename high-confidence files
      $ mix beatgrid.sync_names --list    # list current pending suggestions
  """
  use Mix.Task

  alias Beatgrid.Library.NameSync

  @requirements ["app.start"]
  @max_listed 40

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [yes: :boolean, list: :boolean])
    shell = Mix.shell()

    if opts[:list] do
      list_pending(shell)
    else
      {:ok, %{created: created}} = NameSync.propose()
      shell.info("Proposed #{created} new rename(s).")
      preview(shell)
      if opts[:yes], do: apply_high(shell)
    end

    :ok
  end

  defp preview(shell) do
    by_conf = Enum.group_by(NameSync.list_by(status: :pending), & &1.confidence)
    high = Map.get(by_conf, :high, [])
    review = Map.get(by_conf, :medium, []) ++ Map.get(by_conf, :low, [])

    shell.info("\n== High confidence (auto-rename with --yes): #{length(high)} ==")
    Enum.each(Enum.take(high, @max_listed), &print(shell, &1))

    shell.info("\n== Needs review (medium/low): #{length(review)} ==")
    Enum.each(Enum.take(review, @max_listed), &print(shell, &1))
  end

  defp apply_high(shell) do
    {:ok, %{applied: applied, failed: failed}} = NameSync.apply_auto()
    shell.info("\nAuto-renamed #{applied} high-confidence file(s); #{failed} failed.")
  end

  defp list_pending(shell) do
    pending = NameSync.list_by(status: :pending)
    shell.info("#{length(pending)} pending suggestion(s):")
    Enum.each(pending, &print(shell, &1))
  end

  defp print(shell, suggestion) do
    shell.info("  [#{suggestion.confidence}] #{suggestion.from_filename}")
    shell.info("        → #{suggestion.to_filename}")
  end
end
