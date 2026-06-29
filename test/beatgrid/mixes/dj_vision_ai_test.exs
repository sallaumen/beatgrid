defmodule Beatgrid.Mixes.DjVisionAITest do
  use ExUnit.Case, async: true
  import Mox
  setup :verify_on_exit!
  alias Beatgrid.Mixes.DjVisionAI

  test "group_consecutive merges same names and fills nil gaps with last known" do
    reads = [
      %{ts_ms: 0, dj_name: "A"},
      %{ts_ms: 10_000, dj_name: nil},
      %{ts_ms: 20_000, dj_name: "A"},
      %{ts_ms: 30_000, dj_name: "B"}
    ]

    assert DjVisionAI.group_consecutive(reads) == [
             %{start_ms: 0, dj_name: "A"},
             %{start_ms: 30_000, dj_name: "B"}
           ]
  end

  test "group_consecutive merges casing and trailing (city) variants, keeping the first-seen name" do
    reads = [
      %{ts_ms: 0, dj_name: "DJ RATA"},
      %{ts_ms: 10_000, dj_name: "Dj Rata"},
      %{ts_ms: 20_000, dj_name: "DJ RATA (SP)"},
      %{ts_ms: 30_000, dj_name: "DJ OUTRO"}
    ]

    assert DjVisionAI.group_consecutive(reads) == [
             %{start_ms: 0, dj_name: "DJ RATA"},
             %{start_ms: 30_000, dj_name: "DJ OUTRO"}
           ]
  end

  test "read_grid asks the AI and aligns names to tiles by reading order" do
    expect(Beatgrid.AI.Mock, :complete, fn prompt, _schema, opts ->
      assert prompt =~ "/tmp/grid.jpg"
      assert opts[:add_dir] == ["/tmp"]
      {:ok, %{"names" => ["A", nil]}}
    end)

    assert {:ok, [%{ts_ms: 0, dj_name: "A"}, %{ts_ms: 10_000, dj_name: nil}]} =
             DjVisionAI.read_grid("/tmp/grid.jpg", [0, 10_000])
  end

  test "read_grid pads missing trailing names to nil" do
    expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o -> {:ok, %{"names" => ["A"]}} end)

    assert {:ok, [%{ts_ms: 0, dj_name: "A"}, %{ts_ms: 10_000, dj_name: nil}]} =
             DjVisionAI.read_grid("/tmp/grid.jpg", [0, 10_000])
  end
end
