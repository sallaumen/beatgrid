defmodule Beatgrid.YouTube.TitleParserTest do
  use ExUnit.Case, async: true

  alias Beatgrid.YouTube.TitleParser

  test "splits 'Artist - Title' and strips trailing noise" do
    assert %{artist: "Djavan", title: "Sina"} =
             TitleParser.parse("Djavan - Sina (Official Video)")
  end

  test "handles en/em dashes and bracketed noise" do
    assert %{artist: "Alceu Valença", title: "Anunciação"} =
             TitleParser.parse("Alceu Valença – Anunciação [HD]")
  end

  test "strips common noise tokens anywhere" do
    assert %{artist: "Luiz Gonzaga", title: "Asa Branca"} =
             TitleParser.parse("Luiz Gonzaga - Asa Branca (Áudio Oficial) [Remastered]")
  end

  test "keeps the rest of the title when there are extra dashes" do
    assert %{artist: "A", title: "B - C"} = TitleParser.parse("A - B - C")
  end

  test "no artist when there is no separator" do
    assert %{artist: nil, title: "Forró Pegado ao Vivo"} =
             TitleParser.parse("Forró Pegado ao Vivo")
  end

  test "does not strip meaningful parentheticals that aren't noise" do
    assert %{artist: "Anavitória", title: "Trevo (Tu)"} =
             TitleParser.parse("Anavitória - Trevo (Tu)")
  end

  test "is defensive about non-strings" do
    assert %{artist: nil, title: ""} = TitleParser.parse(nil)
  end

  test "drops the channel branding after a spaced pipe" do
    assert %{artist: "Jota lima", title: "Morena linda"} =
             TitleParser.parse(
               "Jota lima - Morena linda | Vitrola Forrozeira - Forró pé de serra"
             )
  end

  test "drops the pipe tail even without an artist separator" do
    assert %{artist: nil, title: "Vapor do Una"} =
             TitleParser.parse("Vapor do Una | Forró Stream")
  end
end
