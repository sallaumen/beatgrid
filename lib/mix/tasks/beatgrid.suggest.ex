defmodule Mix.Tasks.Beatgrid.Suggest do
  @shortdoc "Create rule-based move suggestions for inbox tracks"
  @moduledoc """
  Creates pending move suggestions for inbox tracks, mapping each track's source
  playlist to a genre folder (see `:playlist_genre_rules` config). Prints the plan;
  nothing moves until you run `mix beatgrid.apply`.
  """
  use Mix.Task

  alias Beatgrid.Organization

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    {:ok, %{batch_id: batch, created: created}} = Organization.suggest_by_rule()

    Mix.shell().info("Created #{created} suggestion(s) — batch #{batch}\n")

    [status: :pending, preload: [:track]]
    |> Organization.list_by()
    |> Enum.each(fn s -> Mix.shell().info("  #{s.track.filename}  →  #{s.to_genre_folder}") end)

    Mix.shell().info("\nReview, then apply with:\n  mix beatgrid.apply #{batch}")
  end
end
