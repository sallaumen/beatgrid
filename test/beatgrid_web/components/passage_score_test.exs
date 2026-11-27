defmodule BeatgridWeb.PassageScoreTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "the score stays out of the flow until a measurement, with a mounted announcement target" do
    dom =
      (&BeatgridWeb.PassageScore.result/1)
      |> render_component(id: "sound-check")
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(
             LazyHTML.query(dom, "[data-score-panel][hidden]"),
             "aria-labelledby"
           ) ==
             ["sound-check-title"]

    assert LazyHTML.text(LazyHTML.query(dom, "#sound-check-title")) == "Nota da passagem"

    assert LazyHTML.attribute(LazyHTML.query(dom, "[data-score-total]"), "aria-hidden") == []
    assert Enum.count(LazyHTML.query(dom, "[data-score-total] [data-score-readable]")) == 1

    assert LazyHTML.attribute(LazyHTML.query(dom, "[data-score-number]"), "aria-hidden") == [
             "true"
           ]

    assert LazyHTML.attribute(LazyHTML.query(dom, "[data-score-announce]"), "aria-live") == [
             "polite"
           ]

    assert LazyHTML.attribute(LazyHTML.query(dom, "[data-score-announce]"), "aria-atomic") == [
             "true"
           ]
  end
end
