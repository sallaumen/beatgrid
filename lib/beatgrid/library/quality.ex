defmodule Beatgrid.Library.Quality do
  @moduledoc """
  Detects quality issues for a track from its audio metadata. Pure — the scanner
  reads metadata via the `Beatgrid.Audio` port and passes the result here.
  """
  alias Beatgrid.Audio.Metadata

  @min_bitrate_kbps 128
  @min_duration_ms 30_000

  @spec detect({:ok, Metadata.t()} | {:error, term()}) :: [atom()]
  def detect({:error, :not_audio}), do: [:not_audio]
  def detect({:error, _reason}), do: [:corrupt]

  def detect({:ok, %Metadata{} = m}) do
    []
    |> flag(:missing_tags, blank?(m.title) or blank?(m.artist))
    |> flag(:low_bitrate, is_integer(m.bitrate_kbps) and m.bitrate_kbps < @min_bitrate_kbps)
    |> flag(:too_short, is_integer(m.duration_ms) and m.duration_ms < @min_duration_ms)
    |> Enum.reverse()
  end

  defp flag(issues, issue, true), do: [issue | issues]
  defp flag(issues, _issue, false), do: issues

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
end
