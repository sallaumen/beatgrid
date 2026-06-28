defmodule Beatgrid.Audio.SetSegmenter.LibrosaCli do
  @moduledoc """
  `SetSegmenter` adapter backed by `priv/scripts/segment_analyze.py` (librosa).
  Shells out with `System.cmd` (one thread per process — same oversubscription
  guard as `Beatgrid.Audio.LibrosaCli`) and parses the JSON array it prints.
  """
  @behaviour Beatgrid.Audio.SetSegmenter

  @thread_env [
    {"OMP_NUM_THREADS", "1"},
    {"OPENBLAS_NUM_THREADS", "1"},
    {"MKL_NUM_THREADS", "1"},
    {"NUMEXPR_NUM_THREADS", "1"},
    {"NUMBA_NUM_THREADS", "1"},
    {"VECLIB_MAXIMUM_THREADS", "1"}
  ]

  @impl Beatgrid.Audio.SetSegmenter
  def analyze(audio_path, boundaries_ms) do
    args = [script(), audio_path, Jason.encode!(boundaries_ms)]

    case System.cmd(python(), args, stderr_to_stdout: false, env: @thread_env) do
      {output, 0} -> parse(output)
      {output, code} -> {:error, {:segment_exit, code, String.slice(output, 0, 500)}}
    end
  rescue
    error -> {:error, {:segment_exception, Exception.message(error)}}
  end

  @doc "Parses the script's JSON array into typed segment maps."
  @spec parse(String.t()) :: {:ok, [Beatgrid.Audio.SetSegmenter.seg()]} | {:error, term()}
  def parse(output) do
    case Jason.decode(output) do
      {:ok, list} when is_list(list) ->
        {:ok, Enum.map(list, &to_seg/1)}

      {:ok, other} ->
        {:error, {:unexpected_output, other}}

      {:error, _} ->
        {:error, {:invalid_json, String.slice(output, 0, 200)}}
    end
  end

  defp to_seg(%{"start_ms" => s, "end_ms" => e} = m) do
    %{
      start_ms: s,
      end_ms: e,
      bpm: num(m["bpm"]),
      key: m["key"],
      mode: m["mode"]
    }
  end

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: nil

  defp python, do: Application.get_env(:beatgrid, __MODULE__, [])[:python] || "python3"
  defp script, do: Application.app_dir(:beatgrid, "priv/scripts/segment_analyze.py")
end
