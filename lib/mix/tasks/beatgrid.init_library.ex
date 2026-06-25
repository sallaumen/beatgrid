defmodule Mix.Tasks.Beatgrid.InitLibrary do
  @shortdoc "Create the library root with genre + structural folders"
  @moduledoc """
  Creates the on-disk library: the library root, one folder per seeded genre
  folder, plus `_Inbox` and `_Quarantine`. Idempotent.

      $ mix beatgrid.init_library
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    {:ok, paths} = Beatgrid.Library.init_library()

    Mix.shell().info("Library ready at #{Beatgrid.Library.library_root()}")
    Enum.each(paths, &Mix.shell().info("  #{&1}"))
  end
end
