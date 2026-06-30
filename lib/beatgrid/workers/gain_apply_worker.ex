defmodule Beatgrid.Workers.GainApplyWorker do
  @moduledoc """
  Applies the calculated loudness gain to one track, then broadcasts a loudness
  tick so dashboard counts refresh.
  """
  use Oban.Worker,
    queue: :loudness,
    max_attempts: 3,
    unique: [period: 30, keys: [:track_id]]

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Loudness

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"track_id" => id} = args}) do
    case Tracks.get(id) do
      nil ->
        :ok

      track ->
        with {:ok, _track} <- Loudness.apply_gain(track, gain_opts(args)) do
          Loudness.broadcast_tick()
          :ok
        end
    end
  end

  defp gain_opts(%{"batch_id" => batch_id}) when is_binary(batch_id), do: [batch_id: batch_id]
  defp gain_opts(_args), do: []
end
