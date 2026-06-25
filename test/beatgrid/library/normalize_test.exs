defmodule Beatgrid.Library.NormalizeTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Library.Normalize

  describe "normalize/1" do
    test "downcases" do
      assert Normalize.normalize("Cor De Mel") == "cor de mel"
    end

    test "strips accents" do
      assert Normalize.normalize("Águas De Março") == "aguas de marco"
      assert Normalize.normalize("Construção") == "construcao"
    end

    test "collapses punctuation and whitespace into single spaces, trimmed" do
      assert Normalize.normalize("  Lua...Luá  ") == "lua lua"
      assert Normalize.normalize("Amor E Sexo!") == "amor e sexo"
    end

    test "keeps digits" do
      assert Normalize.normalize("Coco de Roda 3000") == "coco de roda 3000"
    end

    test "treats spelling/case variants of the same title equally" do
      assert Normalize.normalize("Movimento Da Cidade") ==
               Normalize.normalize("Movimento da Cidade")
    end

    test "handles nil and empty" do
      assert Normalize.normalize(nil) == ""
      assert Normalize.normalize("") == ""
    end
  end
end
