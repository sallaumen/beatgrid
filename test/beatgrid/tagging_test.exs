defmodule Beatgrid.TaggingTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Tagging
  alias Beatgrid.Tagging.Mock

  test "writes the folder's display name as the ID3 genre and mirrors it onto the track" do
    insert(:genre_folder, key: "forro_mpb", display_name: "Forró MPB", dir_name: "Forró MPB")

    track =
      insert(:track,
        rel_path: "Forró MPB/song.mp3",
        filename: "song.mp3",
        genre_folder: "forro_mpb"
      )

    expect(Mock, :write_genre, fn path, genre ->
      assert String.ends_with?(path, "Forró MPB/song.mp3")
      assert genre == "Forró MPB"
      :ok
    end)

    assert {:ok, updated} = Tagging.write_genre(track)
    assert updated.tag_genre == "Forró MPB"
    assert Tracks.get(track.id).tag_genre == "Forró MPB"
  end

  test "errors and writes nothing when the track has no genre folder" do
    track = insert(:track, genre_folder: nil)
    assert {:error, :no_genre_folder} = Tagging.write_genre(track)
  end

  test "errors when the genre folder key is unknown" do
    track = insert(:track, genre_folder: "ghost")
    assert {:error, {:unknown_genre_folder, "ghost"}} = Tagging.write_genre(track)
  end

  test "propagates a writer failure without touching the row" do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    track = insert(:track, rel_path: "MPB/x.mp3", filename: "x.mp3", genre_folder: "mpb")

    expect(Mock, :write_genre, fn _path, _genre -> {:error, :boom} end)

    assert {:error, :boom} = Tagging.write_genre(track)
    assert Tracks.get(track.id).tag_genre == nil
  end
end
