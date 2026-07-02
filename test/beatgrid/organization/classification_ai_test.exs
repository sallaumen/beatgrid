defmodule Beatgrid.Organization.ClassificationAITest do
  # async: false — the auto-apply test overrides the global :library_root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.AI.Mock
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Organization
  alias Beatgrid.Organization.ClassificationAI

  setup :isolate_library_root

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
      t_1 = insert(:track, tag_artist: "Djavan", tag_title: "Sina", genre_folder: "forro_roots")

      t_2 =
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

      assert {:ok, results} = ClassificationAI.classify_tracks([t_1, t_2])

      assert [
               %{track: r_1, folder: "mpb", confidence: 0.82},
               %{track: r_2, folder: "forro_roots"}
             ] = results

      assert r_1.id == t_1.id
      assert r_2.id == t_2.id
    end
  end

  describe "reclassify/1" do
    test "creates a pending :claude move suggestion only where the AI disagrees with the folder" do
      t_1 = insert(:track, tag_artist: "Djavan", genre_folder: "forro_roots", rel_path: "a.mp3")
      _t_2 = insert(:track, tag_artist: "Luiz Gonzaga", genre_folder: "mpb", rel_path: "b.mp3")

      expect(Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok,
         %{
           "classifications" => [
             %{
               "index" => 1,
               "folder" => "mpb",
               "confidence" => 0.79,
               "rationale" => "MPB songwriter"
             },
             %{"index" => 2, "folder" => "mpb", "confidence" => 0.7, "rationale" => "already mpb"}
           ]
         }}
      end)

      assert %{classified: 2, suggested: 1, agreed: 1} = ClassificationAI.reclassify()

      assert [suggestion] = Organization.list_by(status: :pending, source: :claude)
      assert suggestion.track_id == t_1.id
      assert suggestion.to_genre_folder == "mpb"
      assert suggestion.source == :claude
      assert suggestion.confidence == 0.79
    end

    test "does not duplicate a suggestion already pending for a track" do
      t_1 = insert(:track, tag_artist: "Djavan", genre_folder: "forro_roots")

      Organization.create_suggestion(%{
        track_id: t_1.id,
        from_rel_path: t_1.rel_path,
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

      assert %{suggested: 0} = ClassificationAI.reclassify()
      assert Organization.count(status: :pending, source: :claude) == 1
    end
  end

  describe "reclassify/1 auto-apply" do
    @tag :tmp_dir
    test "auto-arquiva (move) quando confidence >= limiar; senão propõe", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "_Inbox"))

      File.write!(Path.join(root, "_Inbox/hi.mp3"), "x")
      File.write!(Path.join(root, "_Inbox/lo.mp3"), "x")

      hi =
        insert(:track,
          status: :present,
          genre_folder: nil,
          rel_path: "_Inbox/hi.mp3",
          filename: "hi.mp3",
          tag_artist: "Alta"
        )

      lo =
        insert(:track,
          status: :present,
          genre_folder: nil,
          rel_path: "_Inbox/lo.mp3",
          filename: "lo.mp3",
          tag_artist: "Baixa"
        )

      expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
        {:ok,
         %{
           "classifications" => [
             %{"index" => 1, "folder" => "mpb", "confidence" => 0.95, "rationale" => "claro"},
             %{"index" => 2, "folder" => "mpb", "confidence" => 0.50, "rationale" => "incerto"}
           ]
         }}
      end)

      ClassificationAI.reclassify(tracks: [hi, lo])

      # alta confiança: movida e arquivada (sai do balde pendente)
      assert Tracks.get(hi.id).genre_folder == "mpb"
      refute File.exists?(Path.join(root, "_Inbox/hi.mp3"))
      # baixa confiança: proposta na Revisão, não movida
      assert is_nil(Tracks.get(lo.id).genre_folder)

      assert Enum.any?(
               Organization.list_by(status: :pending, source: :claude),
               &(&1.track_id == lo.id)
             )
    end
  end

  describe "reclassify/1 with :tracks" do
    test "classifies only the given tracks" do
      inbox = insert(:track, tag_artist: "Djavan", genre_folder: nil, rel_path: "_Inbox/x.mp3")
      _other = insert(:track, tag_artist: "X", genre_folder: "mpb")

      expect(Mock, :complete, fn _p, _s, _o ->
        {:ok,
         %{
           "classifications" => [
             %{"index" => 1, "folder" => "mpb", "confidence" => 0.6, "rationale" => "r"}
           ]
         }}
      end)

      assert %{classified: 1, suggested: 1} = ClassificationAI.reclassify(tracks: [inbox])
      assert [s] = Organization.list_by(status: :pending, source: :claude)
      assert s.track_id == inbox.id
    end
  end
end
