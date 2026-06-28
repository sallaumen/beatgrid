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

  test "read_grid asks the AI and maps tiles" do
    expect(Beatgrid.AI.Mock, :complete, fn prompt, _schema, opts ->
      assert prompt =~ "/tmp/grid.jpg"
      assert opts[:add_dir] == ["/tmp"]
      {:ok, %{"tiles" => [%{"ts_ms" => 0, "dj_name" => "A"}, %{"ts_ms" => 10_000, "dj_name" => nil}]}}
    end)

    assert {:ok, [%{ts_ms: 0, dj_name: "A"}, %{ts_ms: 10_000, dj_name: nil}]} =
             DjVisionAI.read_grid("/tmp/grid.jpg", [0, 10_000])
  end
end
