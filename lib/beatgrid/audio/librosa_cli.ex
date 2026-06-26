defmodule Beatgrid.Audio.LibrosaCli do
  @moduledoc """
  Audio-analysis adapter backed by a small `librosa` Python script
  (`priv/scripts/analyze.py`). Shells out with `System.cmd` and parses the JSON
  `{bpm, key, mode}` it prints. Requires `librosa` installed for the `python3` on
  `PATH` (configurable via `:python`).
  """
  @behaviour Beatgrid.Audio.Analyzer

  @impl Beatgrid.Audio.Analyzer
  def analyze(path) do
    case System.cmd(python(), [script(), path], stderr_to_stdout: false) do
      {output, 0} -> parse(output)
      {output, code} -> {:error, {:analyze_exit, code, String.slice(output, 0, 500)}}
    end
  rescue
    error -> {:error, {:analyze_exception, Exception.message(error)}}
  end

  @doc "Parses the analyzer script's JSON line into the typed result."
  @spec parse(String.t()) ::
          {:ok, %{bpm: float(), key: integer(), mode: integer()}} | {:error, term()}
  def parse(output) do
    case Jason.decode(output) do
      {:ok, %{"bpm" => bpm, "key" => key, "mode" => mode}}
      when is_number(bpm) and is_integer(key) and is_integer(mode) ->
        {:ok, %{bpm: bpm / 1, key: key, mode: mode}}

      {:ok, other} ->
        {:error, {:unexpected_output, other}}

      {:error, _} ->
        {:error, {:invalid_json, String.slice(output, 0, 200)}}
    end
  end

  defp python, do: Application.get_env(:beatgrid, __MODULE__, [])[:python] || "python3"
  defp script, do: Application.app_dir(:beatgrid, "priv/scripts/analyze.py")
end
