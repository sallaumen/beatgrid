defmodule Beatgrid.Workers.MixCutWorker do
  @moduledoc """
  Cuts a validated recorte out of a mix's audio in the background. Unique per
  mix+range so a double submit can't produce twin files; a mix whose audio
  vanished cancels instead of retrying forever.
  """
  use Oban.Worker,
    queue: :mixes,
    max_attempts: 2,
    unique: [period: 300, keys: [:mix_id, :start_ms, :end_ms]]

  alias Beatgrid.Mixes

  @spec enqueue(Uniq.UUID.t(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(mix_id, cut) do
    %{
      mix_id: mix_id,
      start_ms: cut.start_ms,
      end_ms: cut.end_ms,
      artist: cut.artist,
      title: cut.title,
      folder_key: cut.folder_key
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mix_id" => mix_id} = args}) do
    case Mixes.get_with_dj_parts(mix_id) do
      nil -> {:cancel, :mix_not_found}
      mix -> run_cut(mix, args)
    end
  end

  defp run_cut(mix, args) do
    cut = %{
      start_ms: args["start_ms"],
      end_ms: args["end_ms"],
      artist: args["artist"] || "",
      title: args["title"],
      folder_key: args["folder_key"]
    }

    case Mixes.cut_to_track(mix, cut) do
      {:ok, _track} -> :ok
      {:error, :no_audio} -> {:cancel, :no_audio}
      {:error, reason} -> {:error, reason}
    end
  end
end
