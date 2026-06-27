defmodule Beatgrid.Repertoire.RecommendationAITest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.AI.Mock
  alias Beatgrid.Repertoire.RecommendationAI
  alias Beatgrid.Repertoire.RecommendationAI.Gap

  setup do
    insert(:genre_folder,
      key: "forro_roots",
      display_name: "Forró Roots",
      dir_name: "Forró Roots",
      description: "Older traditional forró."
    )

    :ok
  end

  describe "suggest_gaps/2" do
    test "builds a folder-scoped prompt with the artists already owned and returns parsed gaps" do
      insert(:track, genre_folder: "forro_roots", tag_artist: "Luiz Gonzaga", status: :present)

      expect(Mock, :complete, fn prompt, schema, _opts ->
        assert prompt =~ "Forró Roots"
        assert prompt =~ "Luiz Gonzaga"
        assert schema["properties"]["gaps"]

        {:ok,
         %{
           "gaps" => [
             %{
               "artist" => "Jackson do Pandeiro",
               "song" => "Chiclete com Banana",
               "reason" => "essential canon"
             }
           ]
         }}
      end)

      assert {:ok, [%Gap{} = gap]} = RecommendationAI.suggest_gaps("forro_roots")
      assert gap.artist == "Jackson do Pandeiro"
      assert gap.song == "Chiclete com Banana"
      assert gap.reason =~ "canon"
    end

    test "errors for an unknown folder" do
      assert {:error, :unknown_folder} = RecommendationAI.suggest_gaps("nope")
    end
  end
end
