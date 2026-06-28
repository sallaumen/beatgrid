defmodule Beatgrid.Audio.SetSegmenter.LibrosaCliTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.SetSegmenter.LibrosaCli

  test "parse/1 decodes the JSON array of segments (atom keys, bpm float)" do
    json =
      ~s([{"start_ms":0,"end_ms":60000,"bpm":124,"key":7,"mode":1},{"start_ms":60000,"end_ms":120000,"bpm":126.5,"key":2,"mode":0}])

    assert {:ok, segs} = LibrosaCli.parse(json)
    assert [%{start_ms: 0, end_ms: 60_000, bpm: 124.0, key: 7, mode: 1}, s2] = segs
    assert s2.bpm == 126.5 and s2.key == 2 and s2.mode == 0
  end

  test "parse/1 tolerates a null bpm/key (short segment)" do
    json = ~s([{"start_ms":0,"end_ms":1000,"bpm":null,"key":null,"mode":null}])
    assert {:ok, [%{bpm: nil, key: nil, mode: nil}]} = LibrosaCli.parse(json)
  end

  test "parse/1 returns error on invalid JSON" do
    assert {:error, _} = LibrosaCli.parse("not json")
  end
end
