defmodule Beatgrid.Audio.FfmpegLoudness do
  @moduledoc """
  Measures integrated loudness (LUFS) + true peak (dBTP) by shelling out to
  `ffmpeg`'s `loudnorm` filter in measure-only mode (`print_format=json`). One pass,
  offline, quota-free. The JSON block it prints to stderr is parsed by `parse/1`.
  """
  @behaviour Beatgrid.Audio.Loudness

  # `-threads 1` pins each ffmpeg to one core, so several loudness jobs run as clean
  # parallel single-core processes (via the Oban queue) instead of each grabbing all
  # cores and thrashing.
  @args ["-hide_banner", "-nostats", "-threads", "1", "-i"]
  @tail ["-af", "loudnorm=print_format=json", "-f", "null", "-"]

  @impl true
  def measure(path) do
    cond do
      System.find_executable("ffmpeg") == nil ->
        {:error, :ffmpeg_not_found}

      not File.exists?(path) ->
        {:error, :enoent}

      true ->
        {output, _exit} = System.cmd("ffmpeg", @args ++ [path | @tail], stderr_to_stdout: true)
        parse(output)
    end
  end

  @doc """
  Extracts the loudnorm JSON object from ffmpeg's (combined) output and reads the
  integrated loudness + true peak + LRA. The values print as strings; silence yields
  `-inf` for `input_i`, which fails to parse → `{:error, :no_loudness_data}`. Pure.
  """
  @spec parse(String.t()) ::
          {:ok, %{lufs: float(), true_peak: float() | nil, lra: float() | nil}}
          | {:error, :no_loudness_data}
  def parse(output) do
    # loudnorm prints a single flat JSON object (no nested braces). Match flat
    # `{...}` blocks and take the last, so a stray brace in earlier ffmpeg log lines
    # can't swallow it.
    with [json] <- output |> then(&Regex.scan(~r/\{[^{}]*\}/s, &1)) |> List.last(),
         {:ok, map} <- Jason.decode(json),
         {lufs, _} <- to_float(map["input_i"]) do
      {:ok,
       %{
         lufs: lufs,
         true_peak: optional_float(map["input_tp"]),
         lra: optional_float(map["input_lra"])
       }}
    else
      _ -> {:error, :no_loudness_data}
    end
  end

  defp to_float(nil), do: :error
  defp to_float(s) when is_binary(s), do: Float.parse(s)

  defp optional_float(s) do
    case to_float(s) do
      {f, _} -> f
      _ -> nil
    end
  end
end
