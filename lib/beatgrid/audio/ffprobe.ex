defmodule Beatgrid.Audio.Ffprobe do
  @moduledoc "Reads audio metadata by shelling out to `ffprobe` (from the ffmpeg suite)."
  @behaviour Beatgrid.Audio.Behaviour

  alias Beatgrid.Audio.Metadata

  @args ~w(-v quiet -print_format json -show_format -show_streams)

  @impl true
  def read_metadata(path) do
    with {:ok, json} <- probe(path) do
      Metadata.from_ffprobe(json)
    end
  end

  defp probe(path) do
    cond do
      System.find_executable("ffprobe") == nil ->
        {:error, :ffprobe_not_found}

      not File.regular?(path) ->
        {:error, :enoent}

      true ->
        case System.cmd("ffprobe", @args ++ [path], stderr_to_stdout: true) do
          {output, 0} -> decode(output)
          {_output, _nonzero} -> {:error, :ffprobe_failed}
        end
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :ffprobe_bad_output}
    end
  end
end
