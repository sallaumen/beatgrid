defmodule Beatgrid.Repertoire.RecommendationAITest do
  # async: false — inserts genre folders with fixed unique keys; running
  # concurrently with other folder-inserting async tests can deadlock on the
  # genre_folders.key unique index.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.AI.Mock
  alias Beatgrid.Repertoire.RecommendationAI
  alias Beatgrid.Repertoire.RecommendationAI.{Description, Gap}

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

  describe "suggest_description/2" do
    test "builds a prompt with the folder + a sibling and returns a parsed rubric" do
      insert(:genre_folder,
        key: "mpb",
        display_name: "MPB",
        dir_name: "MPB",
        description: "Brazilian popular music."
      )

      expect(Mock, :complete, fn prompt, schema, _opts ->
        assert prompt =~ "Forró Roots"
        assert prompt =~ "MPB"
        assert schema["properties"]["description"]
        assert schema["properties"]["rationale"]

        {:ok,
         %{
           "description" => "Traditional rural forró with pé-de-serra instrumentation.",
           "rationale" => "kept it distinct from MPB and modern forró"
         }}
      end)

      assert {:ok, %Description{} = desc} = RecommendationAI.suggest_description("forro_roots")
      assert desc.description =~ "pé-de-serra"
      assert desc.rationale =~ "distinct"
    end

    test "errors for an unknown folder" do
      assert {:error, :unknown_folder} = RecommendationAI.suggest_description("nope")
    end
  end
end
