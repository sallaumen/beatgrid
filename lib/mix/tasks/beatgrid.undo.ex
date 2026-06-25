defmodule Mix.Tasks.Beatgrid.Undo do
  @shortdoc "Undo the applied moves in a batch"
  @moduledoc """
  Reverses the applied moves in a batch, returning each track to its original
  location.

      $ mix beatgrid.undo <batch_id>
  """
  use Mix.Task

  alias Beatgrid.Organization

  @requirements ["app.start"]

  @impl Mix.Task
  def run([batch | _]) do
    applied = Organization.list_by(status: :applied, batch_id: batch)
    undone = Enum.count(applied, &match?({:ok, _}, Organization.undo(&1)))
    Mix.shell().info("Undid #{undone} of #{length(applied)} move(s) in batch #{batch}.")
  end

  def run(_argv), do: Mix.shell().error("Usage: mix beatgrid.undo <batch_id>")
end
