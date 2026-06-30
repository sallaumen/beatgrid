defmodule Beatgrid.Audio.SetSegmenter.LibrosaCliTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.SetSegmenter.LibrosaCli

  test "parse_lines collects final segments and dispatches progress" do
    on_progress = fn p -> send(self(), {:tick, p}) end

    output = """
    {"progress": {"stage": "segments", "done": 1, "total": 2}}
    {"progress": {"stage": "segments", "done": 2, "total": 2}}
    {"segments": [{"start_ms": 0, "end_ms": 1000, "bpm": 120.0, "key": 7, "mode": 1}]}
    """

    assert {:ok, [seg]} = LibrosaCli.parse_lines(output, :segments, on_progress)
    assert seg.start_ms == 0 and seg.bpm == 120.0
    assert_received {:tick, %{stage: "segments", done: 1, total: 2}}
    assert_received {:tick, %{stage: "segments", done: 2, total: 2}}
  end

  test "parse_lines collects candidates" do
    output = ~s({"candidates": [{"start_ms": 0, "strength": 0.9}]}\n)

    assert {:ok, [%{start_ms: 0, strength: 0.9}]} =
             LibrosaCli.parse_lines(output, :candidates, fn _ -> :ok end)
  end

  test "parse_lines errors when the final line is missing" do
    output = ~s({"progress": {"stage": "segments", "done": 1, "total": 1}}\n)
    assert {:error, _} = LibrosaCli.parse_lines(output, :segments, fn _ -> :ok end)
  end

  test "classify_line recognises progress lines" do
    json = ~s({"progress": {"stage": "bpm", "done": 3, "total": 10}})
    assert {:ok, decoded} = Jason.decode(json)

    assert {:progress, %{stage: "bpm", done: 3, total: 10}} =
             LibrosaCli.classify_line({:ok, decoded})
  end

  test "classify_line recognises segments lines" do
    json = ~s({"segments": [{"start_ms": 0, "end_ms": 1000, "bpm": 120.0, "key": 7, "mode": 1}]})
    assert {:ok, decoded} = Jason.decode(json)
    assert {:segments, [_]} = LibrosaCli.classify_line({:ok, decoded})
  end

  test "classify_line recognises candidates lines" do
    json = ~s({"candidates": [{"start_ms": 0, "strength": 0.9}]})
    assert {:ok, decoded} = Jason.decode(json)
    assert {:candidates, [_]} = LibrosaCli.classify_line({:ok, decoded})
  end

  test "classify_line ignores unknown JSON" do
    assert :ignore = LibrosaCli.classify_line({:ok, %{"unknown" => true}})
  end

  test "classify_line ignores parse errors" do
    assert :ignore = LibrosaCli.classify_line({:error, %Jason.DecodeError{}})
  end

  test "parse_lines tolerates null bpm/key (short segment)" do
    output =
      ~s({"segments": [{"start_ms": 0, "end_ms": 1000, "bpm": null, "key": null, "mode": null}]}\n)

    assert {:ok, [%{bpm: nil, key: nil, mode: nil}]} =
             LibrosaCli.parse_lines(output, :segments, fn _ -> :ok end)
  end
end
