defmodule Mix.Tasks.Beatgrid.Analyze do
  @shortdoc "Detect BPM + key locally (librosa) as a second opinion on every track"
  @moduledoc """
  Runs local audio analysis (`Beatgrid.Analysis`) over present tracks and stores
  the detected BPM + Camelot alongside the Soundcharts metadata. Slow (a few
  seconds per track) and offline — no Soundcharts quota. By default only analyzes
  tracks not yet analyzed; `--all` re-analyzes everything.

      $ mix beatgrid.analyze --limit 5      # a sample first (asks before running)
      $ mix beatgrid.analyze --yes          # all not-yet-analyzed tracks
      $ mix beatgrid.analyze --all --yes    # re-analyze the whole library
  """
  use Mix.Task

  alias Beatgrid.Analysis
  alias Beatgrid.Library.Tracks

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [limit: :integer, all: :boolean, yes: :boolean])

    shell = Mix.shell()

    tracks =
      [status: :present]
      |> Tracks.list_by()
      |> then(&if(opts[:all], do: &1, else: Enum.filter(&1, fn t -> is_nil(t.analyzed_at) end)))
      |> then(&if(opts[:limit], do: Enum.take(&1, opts[:limit]), else: &1))

    n = length(tracks)
    shell.info("Will analyze #{n} track(s) locally with librosa (BPM + key) — this is slow.")

    cond do
      n == 0 -> shell.info("Nothing to analyze. ✔")
      opts[:yes] || shell.yes?("Analyze #{n} tracks?") -> analyze(shell, tracks)
      true -> shell.info("Aborted.")
    end
  end

  defp analyze(shell, tracks) do
    total = length(tracks)

    {ok, fail} =
      tracks
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {track, i}, {ok, fail} ->
        case Analysis.analyze_track(track) do
          {:ok, t} ->
            shell.info(
              "[#{i}/#{total}] #{t.filename} → #{t.bpm_detected} BPM / #{t.camelot_detected}"
            )

            {ok + 1, fail}

          {:error, reason} ->
            shell.error("[#{i}/#{total}] #{track.filename} failed: #{inspect(reason)}")
            {ok, fail + 1}
        end
      end)

    shell.info("Done. #{ok} analyzed, #{fail} failed.")
  end
end
