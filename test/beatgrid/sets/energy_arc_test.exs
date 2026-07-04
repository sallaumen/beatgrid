defmodule Beatgrid.Sets.EnergyArcTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Sets.EnergyArc

  # Compress consecutive same-role slots into {role, run_length}.
  defp runs(plan), do: plan |> Enum.chunk_by(& &1.role) |> Enum.map(&{hd(&1).role, length(&1)})
  defp intensities(plan), do: Enum.map(plan, & &1.target_intensity)

  describe "plan/2 — universal invariants (every shape)" do
    test "empty for non-positive counts" do
      for shape <- EnergyArc.shapes() do
        assert EnergyArc.plan(0, shape) == []
        assert EnergyArc.plan(-3, shape) == []
      end
    end

    test "always exactly count slots with valid roles and intensity in [0,1]" do
      for shape <- EnergyArc.shapes(), n <- [1, 2, 3, 5, 8, 12, 20, 47] do
        plan = EnergyArc.plan(n, shape)
        assert length(plan) == n, "#{shape}/#{n} should have #{n} slots"

        for slot <- plan do
          assert slot.role in ~w(abertura pico respiro queda)
          assert slot.target_intensity >= 0.0 and slot.target_intensity <= 1.0
        end
      end
    end

    test "defaults to :wave" do
      # same shape family — opens on abertura, closes on queda
      plan = EnergyArc.plan(12)
      assert [%{role: "abertura"} | _] = plan
      assert List.last(plan).role == "queda"
    end
  end

  describe "plan/2 :wave — the classic block model (moved from Mixing)" do
    test "tiny sets degrade gracefully" do
      assert [%{role: "abertura"}] = EnergyArc.plan(1, :wave)
      assert [%{role: "abertura"}, %{role: "queda"}] = EnergyArc.plan(2, :wave)
    end

    test "opens on abertura, closes on queda, alternates peaks/valleys" do
      for n <- [12, 16, 20, 24, 30, 40] do
        plan = EnergyArc.plan(n, :wave)
        assert [%{role: "abertura"} | _] = plan
        assert List.last(plan).role == "queda"

        middle = plan |> runs() |> Enum.reject(fn {r, _} -> r in ~w(abertura queda) end)
        assert [{"pico", _} | _] = middle
        assert {"pico", _} = List.last(middle)

        respiros = Enum.filter(middle, fn {r, _} -> r == "respiro" end)
        assert respiros != [], "set de #{n} deveria ter ao menos um respiro"
        for {_, v} <- respiros, do: assert(v in 3..4)

        for {_, p} <- middle |> Enum.filter(&(elem(&1, 0) == "pico")) |> Enum.drop(-1),
            do: assert(p in 4..5)
      end
    end

    test "scales: a bigger set has more peaks" do
      peaks = fn n ->
        EnergyArc.plan(n, :wave) |> runs() |> Enum.count(&(elem(&1, 0) == "pico"))
      end

      assert peaks.(40) > peaks.(14)
    end
  end

  describe "plan/2 :rise — intensity climbs to the end" do
    test "intensity is non-decreasing and ends higher than it starts" do
      is = intensities(EnergyArc.plan(30, :rise))
      assert is == Enum.sort(is), "rise must be monotonically non-decreasing"
      assert List.last(is) > hd(is) + 0.2
      assert List.last(is) >= 0.9, "a rise should crest near the top"
    end
  end

  describe "plan/2 :fall — an early crest, then a long descent" do
    test "peaks early then never climbs again" do
      is = intensities(EnergyArc.plan(30, :fall))
      peak_idx = is |> Enum.with_index() |> Enum.max_by(&elem(&1, 0)) |> elem(1)
      assert peak_idx <= 8, "the crest should be in the first third"
      tail = Enum.drop(is, peak_idx)
      assert tail == Enum.sort(tail, :desc), "after the crest it only descends"
      assert List.last(is) < 0.5
    end
  end

  describe "plan/2 :peak — a symmetric mountain" do
    test "rises to a mid-set crest then descends, ends low on both sides" do
      is = intensities(EnergyArc.plan(31, :peak))
      peak_idx = is |> Enum.with_index() |> Enum.max_by(&elem(&1, 0)) |> elem(1)
      assert peak_idx in 12..18, "the crest should sit near the middle"
      assert hd(is) < 0.7 and List.last(is) < 0.7
      # roughly symmetric: first and last quarters average about the same
      q = div(length(is), 4)
      avg = fn xs -> Enum.sum(xs) / length(xs) end
      assert_in_delta avg.(Enum.take(is, q)), avg.(Enum.take(is, -q)), 0.12
    end
  end

  describe "plan/2 :steady — a plateau" do
    test "hovers around a mid-high intensity with little spread" do
      is = EnergyArc.plan(30, :steady) |> intensities() |> Enum.drop(2) |> Enum.drop(-2)
      assert Enum.max(is) - Enum.min(is) <= 0.15, "a plateau should barely move"
      avg = Enum.sum(is) / length(is)
      assert avg >= 0.7 and avg <= 0.85
    end
  end
end
