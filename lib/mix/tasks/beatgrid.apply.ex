defmodule Mix.Tasks.Beatgrid.Apply do
  @shortdoc "Apply pending move suggestions (optionally a single batch)"
  @moduledoc """
  Applies pending move suggestions — moves each track's file into its target
  genre folder. Pass a batch id to apply only that batch.

      $ mix beatgrid.apply             # all pending
      $ mix beatgrid.apply <batch_id>  # one batch
  """
  use Mix.Task

  alias Beatgrid.Organization

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    opts =
      case argv do
        [batch | _] -> [status: :pending, batch_id: batch]
        [] -> [status: :pending]
      end

    suggestions = Organization.list_by(opts)
    {:ok, %{applied: applied, failed: failed}} = Organization.apply_batch(suggestions)
    Mix.shell().info("Applied #{applied}, failed #{failed}.")
  end
end
