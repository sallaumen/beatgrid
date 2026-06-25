defmodule Mix.Tasks.Beatgrid.Report do
  @shortdoc "Scan a directory and report inventory, quality issues, and duplicates"
  @moduledoc """
  Scans a directory (default: the library root), detects duplicates, and prints a
  report: inventory by format, quality issues with the flagged files, and the
  duplicate groups. Scanned tracks are persisted.

      $ mix beatgrid.report
      $ mix beatgrid.report "~/Music/_Serato_/Imported"
  """
  use Mix.Task

  alias Beatgrid.{Dedup, Library}
  alias Beatgrid.Library.{Scanner, Tracks}

  @requirements ["app.start"]
  @max_listed 25

  @impl Mix.Task
  def run(argv) do
    root = Path.expand(List.first(argv) || Library.library_root())
    shell = Mix.shell()

    shell.info("Scanning #{root} ...")
    {:ok, %{scanned: scanned}} = Scanner.scan(root)
    {:ok, dups} = Dedup.detect()

    tracks = Tracks.list_by(status: :present)

    inventory(shell, scanned, tracks)
    quality(shell, tracks)
    duplicates(shell, dups)

    :ok
  end

  defp inventory(shell, scanned, tracks) do
    shell.info("\n== Inventory ==")
    shell.info("  scanned this run: #{scanned}")
    shell.info("  present tracks:   #{length(tracks)}")
    counts(shell, "  by format:", Enum.frequencies_by(tracks, & &1.format))
  end

  defp quality(shell, tracks) do
    flagged = Enum.filter(tracks, &(&1.quality_issues != []))
    shell.info("\n== Quality (#{length(flagged)} flagged) ==")
    counts(shell, "  by issue:", Enum.frequencies(Enum.flat_map(tracks, & &1.quality_issues)))

    flagged
    |> Enum.take(@max_listed)
    |> Enum.each(fn t -> shell.info("    - #{t.rel_path}  #{inspect(t.quality_issues)}") end)

    overflow(shell, length(flagged))
  end

  defp duplicates(shell, %{exact: exact, fuzzy: fuzzy}) do
    groups = Dedup.list_groups()
    shell.info("\n== Duplicates ==")
    shell.info("  exact-hash groups: #{exact}")
    shell.info("  fuzzy-meta groups: #{fuzzy}")

    groups
    |> Enum.take(15)
    |> Enum.each(&print_group(shell, &1))

    if length(groups) > 15, do: shell.info("  … and #{length(groups) - 15} more groups")
  end

  defp print_group(shell, group) do
    shell.info("  [#{group.match_type}] #{group.signature}")

    Enum.each(group.members, fn member ->
      mark = if member.is_keeper, do: "keep →", else: "      "
      shell.info("    #{mark} #{member.track.rel_path}  (#{member.track.bitrate_kbps} kbps)")
    end)
  end

  defp counts(shell, label, freq) do
    shell.info(label)

    freq
    |> Enum.sort_by(fn {_key, count} -> -count end)
    |> Enum.each(fn {key, count} -> shell.info("    #{key}: #{count}") end)
  end

  defp overflow(shell, total) when total > @max_listed,
    do: shell.info("    … and #{total - @max_listed} more")

  defp overflow(_shell, _total), do: :ok
end
