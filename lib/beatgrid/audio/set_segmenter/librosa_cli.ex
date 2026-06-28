defmodule Beatgrid.Audio.SetSegmenter.LibrosaCli do
  @moduledoc """
  `SetSegmenter` adapter backed by `priv/scripts/segment_analyze.py` (librosa).
  Spawns the script as an Erlang Port in line-mode so progress events are dispatched
  LIVE while the script runs — important for 3h+ mixes. One thread per process (same
  oversubscription guard as `Beatgrid.Audio.LibrosaCli`).
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
  def analyze(audio_path, boundaries_ms, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)
    run([script(), audio_path, Jason.encode!(boundaries_ms)], :segments, on_progress)
  end

  @impl Beatgrid.Audio.SetSegmenter
  def dj_candidates(audio_path) do
    run([script(), "--mode", "dj-candidates", audio_path], :candidates, fn _ -> :ok end)
  end

  defp run(args, final_key, on_progress) do
    exe = System.find_executable(python()) || python()

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        {:line, 1_000_000},
        args: args,
        env: @thread_env
      ])

    collect(port, final_key, on_progress, "", nil)
  rescue
    error -> {:error, {:segment_exception, Exception.message(error)}}
  end

  # Buffer :noeol fragments until the matching :eol completes a line.
  defp collect(port, final_key, on_progress, buf, result) do
    receive do
      {^port, {:data, {:noeol, frag}}} ->
        collect(port, final_key, on_progress, buf <> frag, result)

      {^port, {:data, {:eol, frag}}} ->
        result = handle_line(buf <> frag, final_key, on_progress, result)
        collect(port, final_key, on_progress, "", result)

      {^port, {:exit_status, 0}} ->
        if result, do: {:ok, result}, else: {:error, :no_final_line}

      {^port, {:exit_status, code}} ->
        {:error, {:segment_exit, code}}
    end
  end

  defp handle_line(line, final_key, on_progress, result) do
    case classify_line(Jason.decode(line)) do
      {:progress, p} ->
        on_progress.(p)
        result

      {:segments, list} when final_key == :segments ->
        Enum.map(list, &to_seg/1)

      {:candidates, list} when final_key == :candidates ->
        Enum.map(list, &to_candidate/1)

      _ ->
        result
    end
  end

  @doc "Pure: reduce a full captured output string through the same line handler (for tests)."
  @spec parse_lines(String.t(), :segments | :candidates, (map() -> any())) ::
          {:ok, list()} | {:error, term()}
  def parse_lines(output, final_key, on_progress) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(nil, fn line, acc -> handle_line(line, final_key, on_progress, acc) end)
    |> case do
      nil -> {:error, :no_final_line}
      result -> {:ok, result}
    end
  end

  def classify_line({:ok, %{"progress" => p}}),
    do: {:progress, %{stage: p["stage"], done: p["done"], total: p["total"]}}

  def classify_line({:ok, %{"segments" => list}}) when is_list(list), do: {:segments, list}
  def classify_line({:ok, %{"candidates" => list}}) when is_list(list), do: {:candidates, list}
  def classify_line(_), do: :ignore

  defp to_seg(%{"start_ms" => s, "end_ms" => e} = m) do
    %{
      start_ms: s,
      end_ms: e,
      bpm: num(m["bpm"]),
      key: m["key"],
      mode: m["mode"]
    }
  end

  defp to_candidate(%{"start_ms" => s} = m), do: %{start_ms: s, strength: num(m["strength"]) || 0.0}

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: nil

  defp python, do: Application.get_env(:beatgrid, __MODULE__, [])[:python] || "python3"
  defp script, do: Application.app_dir(:beatgrid, "priv/scripts/segment_analyze.py")
end
