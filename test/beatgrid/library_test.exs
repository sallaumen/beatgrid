defmodule Beatgrid.LibraryTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library

  describe "init_library/1" do
    @tag :tmp_dir
    test "creates the library root with genre dirs + _Inbox + _Quarantine", %{tmp_dir: root} do
      insert(:genre_folder, dir_name: "MPB")
      insert(:genre_folder, dir_name: "Forró")

      assert {:ok, paths} = Library.init_library(root)

      for dir <- ["MPB", "Forró", "_Inbox", "_Quarantine"] do
        assert File.dir?(Path.join(root, dir)), "expected #{dir}/ to exist"
      end

      assert is_list(paths)
    end

    @tag :tmp_dir
    test "is idempotent", %{tmp_dir: root} do
      insert(:genre_folder, dir_name: "MPB")

      assert {:ok, _} = Library.init_library(root)
      assert {:ok, _} = Library.init_library(root)
      assert File.dir?(Path.join(root, "MPB"))
    end
  end

  describe "effective/1" do
    test "prefers Soundcharts, falls back to detected" do
      song = insert(:soundcharts_song, tempo_bpm: 120.0, camelot: "8A", energy: 0.7)

      t =
        insert(:track, soundcharts_song_id: song.id, bpm_detected: 90.0, camelot_detected: "5A")
        |> Repo.preload(:soundcharts_song)

      assert %{bpm: 120.0, camelot: "8A", energy: 0.7} = Library.effective(t)

      t2 =
        insert(:track, bpm_detected: 90.0, camelot_detected: "5A")
        |> Repo.preload(:soundcharts_song)

      assert %{bpm: 90.0, camelot: "5A", energy: nil} = Library.effective(t2)
    end
  end
end
