defmodule Beatgrid.Playback.QuietMode.ObanController do
  @moduledoc "Controls Oban queue execution for playback quiet mode."

  @spec pause(Beatgrid.Playback.QuietMode.scope()) :: :ok | {:error, term()}
  def pause(:all), do: Oban.pause_all_queues(local_only: true)

  def pause(queues) when is_list(queues) do
    each_queue(queues, &Oban.pause_queue(queue: &1, local_only: true))
  end

  @spec resume(Beatgrid.Playback.QuietMode.scope()) :: :ok | {:error, term()}
  def resume(:all), do: Oban.resume_all_queues(local_only: true)

  def resume(queues) when is_list(queues) do
    each_queue(queues, &Oban.resume_queue(queue: &1, local_only: true))
  end

  defp each_queue(queues, fun) do
    queues
    |> Enum.map(fun)
    |> Enum.find(&match?({:error, _}, &1))
    |> case do
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
