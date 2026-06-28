defmodule Beatgrid.Audio.SetSegmenter.LibrosaCliPortTest do
  # Exercises the REAL Erlang Port path (Port.open + collect/5), which the mocked
  # SetSegmenter and the python smoke test never cover. This is the path where the
  # binary-vs-charlist :env bug lived. Uses a fake `sh` "script" emitting the line
  # protocol, so it's hermetic (no python/librosa/ffmpeg, no network).
  use ExUnit.Case, async: false

  alias Beatgrid.Audio.SetSegmenter.LibrosaCli

  @key Beatgrid.Audio.SetSegmenter.LibrosaCli

  setup do
    fake = Path.join(System.tmp_dir!(), "fake_segmenter_#{System.unique_integer([:positive])}.sh")

    File.write!(fake, """
    #!/bin/sh
    if [ "$1" = "--mode" ]; then
      echo '{"candidates": [{"start_ms": 300000, "strength": 0.9}]}'
    else
      echo '{"progress": {"stage": "segments", "done": 1, "total": 1}}'
      echo '{"segments": [{"start_ms": 0, "end_ms": 1000, "bpm": 120.0, "key": 7, "mode": 1}]}'
    fi
    """)

    prev = Application.get_env(:beatgrid, @key)
    Application.put_env(:beatgrid, @key, python: "/bin/sh", script: fake)

    on_exit(fn ->
      if prev, do: Application.put_env(:beatgrid, @key, prev), else: Application.delete_env(:beatgrid, @key)
      File.rm(fake)
    end)

    :ok
  end

  test "analyze/3 runs the script via a Port, parses segments, and dispatches progress live" do
    parent = self()
    on_progress = fn p -> send(parent, {:tick, p}) end

    assert {:ok, [seg]} = LibrosaCli.analyze("x.mp3", [], on_progress: on_progress)
    assert seg.start_ms == 0 and seg.end_ms == 1000 and seg.bpm == 120.0 and seg.key == 7
    assert_received {:tick, %{stage: "segments", done: 1, total: 1}}
  end

  test "dj_candidates/1 runs the script via a Port and parses candidates" do
    assert {:ok, [%{start_ms: 300_000, strength: 0.9}]} = LibrosaCli.dj_candidates("x.mp3")
  end
end
