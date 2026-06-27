defmodule Beatgrid.Library.MetadataAITest do
  use Beatgrid.DataCase, async: false

  import Mox
  import Beatgrid.Factory

  alias Beatgrid.Library.MetadataAI
  alias Beatgrid.Library.MetadataAI.{ParsedTitle, Resolution}

  setup :verify_on_exit!

  describe "resolve_names/1" do
    test "resolve_names maps the AI verdict per track" do
      insert(:genre_folder,
        key: "forro_roots",
        display_name: "Forró Roots",
        dir_name: "Forró Roots",
        description: "raiz"
      )

      song = insert(:soundcharts_song, credit_name: "Caetano Veloso", name: "Cajuína")

      track =
        insert(:track,
          status: :present,
          genre_folder: "forro_roots",
          tag_artist: nil,
          tag_title: "Cajuina",
          filename: "Cajuina.mp3",
          soundcharts_song_id: song.id
        )

      expect(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
        {:ok,
         %{
           "resolutions" => [
             %{
               "index" => 1,
               "same_recording" => false,
               "artist" => "Forró In The Dark",
               "title" => "Cajuína",
               "confidence" => 0.7,
               "rationale" => "Versão forró, não a do Caetano"
             }
           ]
         }}
      end)

      assert {:ok, [%Resolution{} = r]} = MetadataAI.resolve_names([track])
      assert r.track.id == track.id
      assert r.same_recording == false
      assert r.artist == "Forró In The Dark"
      assert r.title == "Cajuína"
      assert r.confidence == 0.7
      assert r.rationale =~ "forró"
    end
  end

  describe "parse_titles/1" do
    test "asks the AI to extract artist/title from raw video titles" do
      expect(Beatgrid.AI.Mock, :complete, fn prompt, schema, _opts ->
        assert prompt =~ "ANAVITÓRIA"
        assert schema["properties"]["titles"]
        {:ok, %{"titles" => [%{"artist" => "Anavitória", "title" => "Trevo"}]}}
      end)

      assert {:ok, [%ParsedTitle{artist: "Anavitória", title: "Trevo"}]} =
               MetadataAI.parse_titles(["ANAVITÓRIA - Trevo (Tu) ft. Tiago Iorc | Lyric Video"])
    end

    test "parse_titles maps each raw title to a ParsedTitle" do
      Mox.expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
        {:ok, %{"titles" => [%{"artist" => "Djavan", "title" => "Sina"}]}}
      end)

      assert {:ok, [%ParsedTitle{artist: "Djavan", title: "Sina"}]} =
               MetadataAI.parse_titles(["Djavan - Sina (Official Video)"])
    end

    test "returns {:ok, []} without calling the AI for an empty list" do
      assert {:ok, []} = MetadataAI.parse_titles([])
    end
  end
end
