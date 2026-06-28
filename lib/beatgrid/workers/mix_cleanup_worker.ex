defmodule Beatgrid.Workers.MixCleanupWorker do
  @moduledoc """
  Deletes a mix's cached audio file ~24h after analysis (scheduled by
  `MixAnalyzeWorker`). The analysis/segments are kept forever — only the large
  audio file is purged. Cancelable via `Mixes.cancel_cleanup/1` ("Manter arquivo").
  """
  use Oban.Worker, queue: :mixes, max_attempts: 3

  alias Beatgrid.Mixes

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mix_id" => mix_id}}) do
    case Mixes.get_mix(mix_id) do
      nil -> :ok
      mix -> with {:ok, _} <- Mixes.purge_audio(mix), do: :ok
    end
  end
end
