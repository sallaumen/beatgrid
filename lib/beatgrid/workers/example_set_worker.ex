defmodule Beatgrid.Workers.ExampleSetWorker do
  @moduledoc """
  One-shot deliverable: builds the example `forro_roots` set, detects cue markers
  (intro/outro/sections) for each track, then auto-connects every consecutive pair —
  a fully-marked + connected set ready to autoplay with DJ transitions. Marker
  detection is best-effort per track (a failure on one doesn't abort the rest).
  Queued on `:analysis` (librosa is CPU-heavy).
  """
  use Oban.Worker, queue: :analysis, max_attempts: 1

  alias Beatgrid.Markers
  alias Beatgrid.Sets

  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(_job) do
    case Sets.build_example() do
      {:error, reason} ->
        {:cancel, reason}

      {:ok, set} ->
        Enum.each(Sets.tracks(set), &Markers.detect/1)
        Sets.connect_all(set)
        :ok
    end
  end
end
