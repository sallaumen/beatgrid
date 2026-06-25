defmodule Mix.Tasks.Beatgrid.Import do
  @shortdoc "Copy audio from a source folder into the library _Inbox"
  @moduledoc """
  Copies audio files from a source directory into the library `_Inbox`, skipping
  exact duplicates already in the library. Originals are left untouched.

      $ mix beatgrid.import "~/Music/_Serato_/Imported"
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([source | _]) do
    {:ok, %{imported: imported, skipped: skipped}} = Beatgrid.Library.import_from(source)
    Mix.shell().info("Imported #{imported}, skipped #{skipped} duplicate(s).")
  end

  def run(_argv), do: Mix.shell().error("Usage: mix beatgrid.import <source_dir>")
end
