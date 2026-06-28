defmodule Beatgrid.Workers.MixCleanupWorker do
  @moduledoc """
  Deletes the local audio file for a mix after the analysis retention window (24h).
  Stub — Task 2.4 will flesh this out.
  """
  use Oban.Worker, queue: :mixes

  @impl Oban.Worker
  def perform(_job), do: :ok
end
