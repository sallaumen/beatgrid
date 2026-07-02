defmodule Beatgrid.Library.NameSyncTest do
  # async: false — overrides the global :library_root app env and touches disk.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Library.{NameSync, Tracks}

  setup :isolate_library_root

  describe "canonical_filename/3" do
    test "joins artist and title and keeps the extension" do
      assert NameSync.canonical_filename("Trio Ternura", "A Gira", ".mp3") ==
               "Trio Ternura - A Gira.mp3"
    end

    test "sanitizes path separators and collapses whitespace" do
      assert NameSync.canonical_filename("Wesley", "Seis / Baião  de Dois", ".mp3") ==
               "Wesley - Seis - Baião de Dois.mp3"
    end
  end

  describe "propose/0 + apply_auto/0" do
    @tag :tmp_dir
    test "auto-renames high-confidence files on disk and updates the row", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/Enxuga o Rato.mp3"), "audio")

      song = insert(:soundcharts_song, credit_name: "Zé Ranulfo", name: "Enxuga o Rato")

      track =
        insert(:track,
          rel_path: "MPB/Enxuga o Rato.mp3",
          filename: "Enxuga o Rato.mp3",
          genre_folder: "mpb",
          soundcharts_song_id: song.id,
          sc_match_confidence: :high
        )

      assert {:ok, %{created: 1}} = NameSync.propose()
      assert {:ok, %{applied: 1, failed: 0}} = NameSync.apply_auto()

      assert File.exists?(Path.join(root, "MPB/Zé Ranulfo - Enxuga o Rato.mp3"))
      refute File.exists?(Path.join(root, "MPB/Enxuga o Rato.mp3"))

      reloaded = Tracks.get(track.id)
      assert reloaded.filename == "Zé Ranulfo - Enxuga o Rato.mp3"
      assert reloaded.rel_path == "MPB/Zé Ranulfo - Enxuga o Rato.mp3"
    end

    @tag :tmp_dir
    test "leaves low-confidence matches as pending suggestions, untouched on disk", %{
      tmp_dir: root
    } do
      File.mkdir_p!(Path.join(root, "Forró Roots"))
      File.write!(Path.join(root, "Forró Roots/Baiao.mp3"), "audio")

      song = insert(:soundcharts_song, credit_name: "Wesley Safadão", name: "Seis Cordas / Baião")

      insert(:track,
        rel_path: "Forró Roots/Baiao.mp3",
        filename: "Baiao.mp3",
        soundcharts_song_id: song.id,
        sc_match_confidence: :low
      )

      assert {:ok, %{created: 1}} = NameSync.propose()
      assert {:ok, %{applied: 0, failed: 0}} = NameSync.apply_auto()

      assert File.exists?(Path.join(root, "Forró Roots/Baiao.mp3"))
      assert [suggestion] = NameSync.list_by(status: :pending)
      assert suggestion.confidence == :low
      assert suggestion.to_filename == "Wesley Safadão - Seis Cordas - Baião.mp3"
    end

    @tag :tmp_dir
    test "skips files whose name already matches the canonical", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/Artist - Song.mp3"), "audio")
      song = insert(:soundcharts_song, credit_name: "Artist", name: "Song")

      insert(:track,
        rel_path: "MPB/Artist - Song.mp3",
        filename: "Artist - Song.mp3",
        soundcharts_song_id: song.id,
        sc_match_confidence: :high
      )

      assert {:ok, %{created: 0}} = NameSync.propose()
    end

    test "proposes from the tags when there is no Soundcharts match, capped at :medium" do
      insert(:track,
        rel_path: "_Inbox/ekPJXrNwsAc.mp3",
        filename: "ekPJXrNwsAc.mp3",
        soundcharts_song_id: nil,
        tag_artist: "Luiz Gonzaga",
        tag_title: "Penerando"
      )

      assert {:ok, %{created: 1}} = NameSync.propose()

      assert [suggestion] = NameSync.list_by(status: :pending)
      assert suggestion.to_filename == "Luiz Gonzaga - Penerando.mp3"
      assert suggestion.confidence == :medium
      assert suggestion.reason == "tags: Luiz Gonzaga - Penerando"

      # never auto-applied: tag-backed proposals wait for review
      assert {:ok, %{applied: 0, failed: 0}} = NameSync.apply_auto()
    end

    test "skips unmatched tracks without usable tags or already-canonical names" do
      insert(:track,
        rel_path: "_Inbox/mystery.mp3",
        filename: "mystery.mp3",
        soundcharts_song_id: nil,
        tag_artist: nil,
        tag_title: nil
      )

      insert(:track,
        rel_path: "_Inbox/Luiz Gonzaga - Penerando.mp3",
        filename: "Luiz Gonzaga - Penerando.mp3",
        soundcharts_song_id: nil,
        tag_artist: "Luiz Gonzaga",
        tag_title: "Penerando"
      )

      assert {:ok, %{created: 0}} = NameSync.propose()
    end
  end

  describe "undo/1" do
    @tag :tmp_dir
    test "reverses an applied rename", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/Old.mp3"), "a")
      song = insert(:soundcharts_song, credit_name: "Artist", name: "New")

      track =
        insert(:track,
          rel_path: "MPB/Old.mp3",
          filename: "Old.mp3",
          soundcharts_song_id: song.id,
          sc_match_confidence: :high
        )

      {:ok, _} = NameSync.propose()
      {:ok, _} = NameSync.apply_auto()
      assert [applied] = NameSync.list_by(status: :applied)

      assert {:ok, _undone} = NameSync.undo(applied)
      assert File.exists?(Path.join(root, "MPB/Old.mp3"))
      assert Tracks.get(track.id).filename == "Old.mp3"
    end
  end
end
