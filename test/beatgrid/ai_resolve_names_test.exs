defmodule Beatgrid.AIResolveNamesTest do
  use Beatgrid.DataCase, async: false

  import Mox
  import Beatgrid.Factory

  setup :verify_on_exit!

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

    assert {:ok, [r]} = Beatgrid.AI.resolve_names([track])
    assert r.track.id == track.id
    assert r.same_recording == false
    assert r.artist == "Forró In The Dark"
    assert r.title == "Cajuína"
    assert r.confidence == 0.7
    assert r.rationale =~ "forró"
  end
end
