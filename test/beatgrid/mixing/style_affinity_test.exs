defmodule Beatgrid.Mixing.StyleAffinityTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Mixing.StyleAffinity

  describe "affinity/2" do
    test "the same folder is fully compatible" do
      assert StyleAffinity.affinity("forro_roots", "forro_roots") == 1.0
    end

    test "a compatible pair scores high, and it's symmetric" do
      assert StyleAffinity.affinity("mpb", "forro_mpb") == 1.0
      assert StyleAffinity.affinity("forro_mpb", "mpb") == 1.0
    end

    test "a 'with care' pair scores in the middle" do
      assert StyleAffinity.affinity("mpb", "forro_in_the_light") == 0.5
    end

    test "an incompatible pair scores low (the Forró Roots rule)" do
      assert StyleAffinity.affinity("forro_roots", "mpb") == 0.15
      assert StyleAffinity.affinity("forro_roots", "forro_psicodelico") == 0.15
    end

    test "a nil target style is neutral (no style penalty)" do
      assert StyleAffinity.affinity(nil, "mpb") == 0.7
      assert StyleAffinity.affinity("mpb", nil) == 0.7
    end
  end

  describe "tier/2" do
    test "maps affinity to a display tier" do
      assert StyleAffinity.tier("forro", "forro_classico") == :combina
      assert StyleAffinity.tier("mpb", "forro_in_the_light") == :cuidado
      assert StyleAffinity.tier("forro_roots", "mpb") == :evitar
    end
  end

  test "folders/0 lists the known genre-folder keys" do
    folders = StyleAffinity.folders()
    assert "forro_roots" in folders
    assert "mpb" in folders
    assert length(folders) == 7
  end
end
