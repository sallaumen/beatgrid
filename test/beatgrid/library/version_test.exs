defmodule Beatgrid.Library.VersionTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Library.Version

  describe "label/1" do
    test "detects version markers in PT and EN, nil for an original" do
      assert Version.label("Asa Branca (Ao Vivo)") == "ao vivo"
      assert Version.label("Song (Live)") == "ao vivo"
      assert Version.label("Track (Acústico)") == "acústico"
      assert Version.label("Disritmia (Remix)") == "remix"
      assert Version.label("Construção - Remastered") == "remaster"
      assert Version.label("Tema (Instrumental)") == "instrumental"
      assert Version.label("Sina") == nil
    end

    test "word boundaries — does not false-match inside other words" do
      assert Version.label("Alive and Well") == nil
      assert Version.label("Demonstração") == nil
    end
  end

  describe "base_title/1" do
    test "strips the marker so versions share a base" do
      assert Version.base_title("Asa Branca (Ao Vivo)") == "asa branca"
      assert Version.base_title("Asa Branca") == "asa branca"
      assert Version.base_title("Song (Live)") == Version.base_title("Song")
      assert Version.base_title("Disritmia (Remix)") == "disritmia"
    end

    test "falls back to the full title when stripping would empty it" do
      assert Version.base_title("Live") == "live"
    end

    test "drops year + mix qualifiers only when a marker is present" do
      # remaster-with-year and extended-mix collapse to the original's base
      assert Version.base_title("Imagine (Remastered 2011)") == "imagine"
      assert Version.base_title("Imagine - 2009 Remaster") == "imagine"
      assert Version.base_title("Track (Extended Mix)") == "track"
      # no marker → a year in the real title is preserved
      assert Version.base_title("1979") == "1979"
    end
  end

  describe "expanded marker set" do
    test "detects vip, mashup, a cappella and generic edit" do
      assert Version.label("Beat (VIP)") == "vip"
      assert Version.label("Track (Mashup)") == "mashup"
      assert Version.label("Hymn (A Cappella)") == "acapella"
      assert Version.label("Song - Edit") == "edit"
    end
  end

  describe "base_key/2" do
    test "same base key across versions of the same song by the same artist" do
      assert Version.base_key("Luiz Gonzaga", "Asa Branca (Ao Vivo)") ==
               Version.base_key("Luiz Gonzaga", "Asa Branca")
    end

    test "different artists never share a base key" do
      refute Version.base_key("A", "Song") == Version.base_key("B", "Song")
    end
  end
end
