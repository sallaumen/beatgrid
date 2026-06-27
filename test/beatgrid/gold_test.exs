defmodule Beatgrid.GoldTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Gold
  alias Beatgrid.Library.Tracks

  describe "candidate?/1" do
    test "youtube sem ISRC é candidato" do
      assert Gold.candidate?(%{source_playlist: "youtube", tag_isrc: nil})
      assert Gold.candidate?(%{source_playlist: "youtube"})
    end

    test "com ISRC ou não-youtube não é candidato" do
      refute Gold.candidate?(%{source_playlist: "youtube", tag_isrc: "BRABC1234567"})
      refute Gold.candidate?(%{source_playlist: "import", tag_isrc: nil})
    end
  end

  describe "popular?/1 + effective/1" do
    test "views acima do limiar é popular" do
      assert Gold.popular?(%Beatgrid.Library.Track{youtube_views: Gold.view_threshold()})
      refute Gold.popular?(%Beatgrid.Library.Track{youtube_views: 10})
      refute Gold.popular?(%Beatgrid.Library.Track{youtube_views: nil})
    end

    test "precedência: manual > popular > confirmado > candidato" do
      hi = Gold.view_threshold() + 1
      assert {true, :manual} = Gold.effective(%Beatgrid.Library.Track{gold_manual: true})

      assert {false, nil} =
               Gold.effective(%Beatgrid.Library.Track{gold_manual: false, youtube_views: hi})

      assert {true, :popular} = Gold.effective(%Beatgrid.Library.Track{youtube_views: hi})

      assert {true, :raro_confirmado} =
               Gold.effective(%Beatgrid.Library.Track{gold_status: :confirmed})

      assert {true, :raro_candidato} =
               Gold.effective(%Beatgrid.Library.Track{gold_status: :candidate})

      assert {false, nil} = Gold.effective(%Beatgrid.Library.Track{})
    end
  end

  describe "apply_resolve_result/2" do
    test "match rebaixa o eixo raro; no_match confirma; budget/already_linked não tocam" do
      cand = insert(:track, gold_status: :candidate)
      assert {:ok, t} = Gold.apply_resolve_result(cand, {:ok, %Beatgrid.Soundcharts.Song{}})
      assert is_nil(Tracks.get(t.id).gold_status)

      cand2 = insert(:track, gold_status: :candidate)
      assert {:ok, t2} = Gold.apply_resolve_result(cand2, {:error, :no_match})
      assert Tracks.get(t2.id).gold_status == :confirmed

      cand3 = insert(:track, gold_status: :candidate)
      assert :ok = Gold.apply_resolve_result(cand3, {:error, :budget_exhausted})
      assert Tracks.get(cand3.id).gold_status == :candidate
    end

    test "already_linked é no-op" do
      linked = insert(:track, gold_status: :candidate)
      assert {:ok, ^linked} = Gold.apply_resolve_result(linked, {:ok, :already_linked})
      assert Tracks.get(linked.id).gold_status == :candidate
    end
  end

  describe "maybe_mark_candidate/1" do
    test "marca candidato só quando status e manual estão nil" do
      t = insert(:track, source_playlist: "youtube", tag_isrc: nil)
      assert {:ok, _} = Gold.maybe_mark_candidate(t)
      assert Tracks.get(t.id).gold_status == :candidate

      conf = insert(:track, source_playlist: "youtube", tag_isrc: nil, gold_status: :confirmed)
      assert {:ok, _} = Gold.maybe_mark_candidate(conf)
      assert Tracks.get(conf.id).gold_status == :confirmed
    end
  end
end
