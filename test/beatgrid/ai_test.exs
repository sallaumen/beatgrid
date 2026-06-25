defmodule Beatgrid.AITest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.AI
  alias Beatgrid.AI.Mock
  alias Beatgrid.Organization

  setup do
    insert(:genre_folder,
      key: "mpb",
      display_name: "MPB",
      dir_name: "MPB",
      description: "Songwriter Brazilian pop, not forró."
    )

    insert(:genre_folder,
      key: "forro_roots",
      display_name: "Forró Roots",
      dir_name: "Forró Roots",
      description: "Older traditional forró."
    )

    :ok
  end

  describe "classify_tracks/1" do
    test "constrains folder to the genre keys and maps results back to tracks by index" do
      t1 = insert(:track, tag_artist: "Djavan", tag_title: "Sina", genre_folder: "forro_roots")

      t2 =
        insert(:track, tag_artist: "Luiz Gonzaga", tag_title: "Asa Branca", genre_folder: "mpb")

      expect(Mock, :complete, fn prompt, schema, _opts ->
        assert is_binary(prompt)
        enum = schema["properties"]["classifications"]["items"]["properties"]["folder"]["enum"]
        assert Enum.sort(enum) == ["forro_roots", "mpb"]

        {:ok,
         %{
           "classifications" => [
             %{
               "index" => 1,
               "folder" => "mpb",
               "confidence" => 0.82,
               "rationale" => "MPB songwriter"
             },
             %{
               "index" => 2,
               "folder" => "forro_roots",
               "confidence" => 0.9,
               "rationale" => "forró canon"
             }
           ]
         }}
      end)

      assert {:ok, results} = AI.classify_tracks([t1, t2])

      assert [%{track: r1, folder: "mpb", confidence: 0.82}, %{track: r2, folder: "forro_roots"}] =
               results

      assert r1.id == t1.id
      assert r2.id == t2.id
    end
  end

  describe "reclassify/1" do
    test "creates a pending :claude move suggestion only where the AI disagrees with the folder" do
      t1 = insert(:track, tag_artist: "Djavan", genre_folder: "forro_roots")
      _t2 = insert(:track, tag_artist: "Luiz Gonzaga", genre_folder: "mpb")

      expect(Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok,
         %{
           "classifications" => [
             %{
               "index" => 1,
               "folder" => "mpb",
               "confidence" => 0.8,
               "rationale" => "MPB songwriter"
             },
             %{"index" => 2, "folder" => "mpb", "confidence" => 0.7, "rationale" => "already mpb"}
           ]
         }}
      end)

      assert %{classified: 2, suggested: 1, agreed: 1} = AI.reclassify()

      assert [suggestion] = Organization.list_by(status: :pending, source: :claude)
      assert suggestion.track_id == t1.id
      assert suggestion.to_genre_folder == "mpb"
      assert suggestion.source == :claude
      assert suggestion.confidence == 0.8
    end

    test "does not duplicate a suggestion already pending for a track" do
      t1 = insert(:track, tag_artist: "Djavan", genre_folder: "forro_roots")

      Organization.create_suggestion(%{
        track_id: t1.id,
        from_rel_path: t1.rel_path,
        to_genre_folder: "mpb",
        source: :claude
      })

      expect(Mock, :complete, fn _p, _s, _o ->
        {:ok,
         %{
           "classifications" => [
             %{"index" => 1, "folder" => "mpb", "confidence" => 0.8, "rationale" => "x"}
           ]
         }}
      end)

      assert %{suggested: 0} = AI.reclassify()
      assert Organization.count(status: :pending, source: :claude) == 1
    end
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

      assert {:ok, [gap]} = AI.suggest_gaps("forro_roots")
      assert gap.artist == "Jackson do Pandeiro"
      assert gap.song == "Chiclete com Banana"
      assert gap.reason =~ "canon"
    end

    test "errors for an unknown folder" do
      assert {:error, :unknown_folder} = AI.suggest_gaps("nope")
    end
  end
end
