defmodule Beatgrid.ReviewTest do
  # async: false — apply_approved/0 touches disk and overrides :library_root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Organization
  alias Beatgrid.Review
  alias Beatgrid.Soundcharts.Response
  alias Beatgrid.Tagging.Mock

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  defp search_response(items),
    do: {:ok, %Response{data: items, quota_remaining: 999, status: 200}}

  defp song_attrs do
    %{
      sc_uuid: "uuid-1",
      name: "Disritmia",
      credit_name: "Casuarina",
      isrc: "BRKMM0900046",
      release_date: ~D[2010-01-05],
      label: "Agente Digital",
      genres: [],
      tempo_bpm: 141.57,
      music_key: 11,
      music_mode: 0,
      energy: 0.63,
      valence: 0.87,
      danceability: 0.72,
      raw: %{}
    }
  end

  describe "decisions" do
    test "approve, reject and edit drive the rename suggestion's status and target" do
      song = insert(:soundcharts_song, credit_name: "Artist", name: "Song")

      insert(:track,
        filename: "x.mp3",
        rel_path: "MPB/x.mp3",
        soundcharts_song_id: song.id,
        sc_match_confidence: :medium
      )

      {:ok, _} = NameSync.propose()
      [r] = NameSync.list_by(status: :pending)

      assert {:ok, _} = Review.approve(r)
      assert NameSync.get(r.id).status == :approved

      assert {:ok, _} = Review.reject(NameSync.get(r.id))
      assert NameSync.get(r.id).status == :rejected

      assert {:ok, _} = Review.edit(NameSync.get(r.id), "Custom - Name.mp3")
      edited = NameSync.get(r.id)
      assert edited.to_filename == "Custom - Name.mp3"
      assert edited.status == :approved
    end

    test "approve_high_confidence approves only high-confidence pending items per tab" do
      insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
      t1 = insert(:track, rel_path: "_Inbox/a.mp3", filename: "a.mp3")
      t2 = insert(:track, rel_path: "_Inbox/b.mp3", filename: "b.mp3")

      {:ok, high} =
        Organization.create_suggestion(%{
          track_id: t1.id,
          from_rel_path: "_Inbox/a.mp3",
          to_genre_folder: "mpb",
          source: :claude,
          confidence: 0.95
        })

      {:ok, low} =
        Organization.create_suggestion(%{
          track_id: t2.id,
          from_rel_path: "_Inbox/b.mp3",
          to_genre_folder: "mpb",
          source: :claude,
          confidence: 0.4
        })

      Review.approve_high_confidence(:classifications)

      assert Organization.get(high.id).status == :approved
      assert Organization.get(low.id).status == :pending
    end
  end

  describe "audit actions" do
    test "dismiss_audit strips the [audit:...] flag, keeping it as a normal rename" do
      song = insert(:soundcharts_song, credit_name: "A", name: "B")

      insert(:track,
        filename: "x.mp3",
        rel_path: "MPB/x.mp3",
        soundcharts_song_id: song.id,
        sc_match_confidence: :medium
      )

      {:ok, _} = NameSync.propose()
      [s] = NameSync.list_by(status: :pending)
      {:ok, flagged} = NameSync.set_reason(s, "[audit:verify/title] soundcharts: A - B")

      assert {:ok, cleaned} = Review.dismiss_audit(flagged)
      assert cleaned.reason == "soundcharts: A - B"
    end

    @tag :tmp_dir
    test "quarantine_track moves the file to _Quarantine and rejects the suggestion", %{
      tmp_dir: root
    } do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/bad.mp3"), "x")
      song = insert(:soundcharts_song, credit_name: "A", name: "B")

      track =
        insert(:track,
          rel_path: "MPB/bad.mp3",
          filename: "bad.mp3",
          genre_folder: "mpb",
          soundcharts_song_id: song.id,
          sc_match_confidence: :low
        )

      {:ok, _} = NameSync.propose()
      [s] = NameSync.list_by(status: :pending)

      assert {:ok, _} = Review.quarantine_track(s)
      assert File.exists?(Path.join(root, "_Quarantine/bad.mp3"))
      refute File.exists?(Path.join(root, "MPB/bad.mp3"))
      assert Tracks.get(track.id).status == :quarantined
      assert NameSync.get(s.id).status == :rejected
    end

    test "re_resolve relinks the track, rejects the suspect rename, and re-proposes" do
      wrong = insert(:soundcharts_song, credit_name: "Wrong", name: "Song")

      track =
        insert(:track,
          tag_title: "Disritmia",
          tag_artist: "Casuarina",
          norm_title: "disritmia",
          norm_artist: "casuarina",
          filename: "old.mp3",
          rel_path: "MPB/old.mp3",
          soundcharts_song_id: wrong.id,
          sc_match_confidence: :low
        )

      {:ok, _} = NameSync.propose()
      [s] = NameSync.list_by(status: :pending)
      {:ok, flagged} = NameSync.set_reason(s, "[audit:wrong_song] suspect")

      expect(Beatgrid.Soundcharts.Mock, :search_song, fn _term ->
        search_response([
          %{uuid: "uuid-1", name: "Disritmia", credit_name: "Casuarina", release_date: nil}
        ])
      end)

      expect(Beatgrid.Soundcharts.Mock, :get_song, fn "uuid-1" ->
        {:ok, %Response{data: song_attrs(), quota_remaining: 998, status: 200}}
      end)

      assert {:ok, :resolved} = Review.re_resolve(flagged)
      assert NameSync.get(flagged.id).status == :rejected
      assert Tracks.get_with_song(track.id).soundcharts_song.credit_name == "Casuarina"
      assert [fresh] = NameSync.list_by(status: :pending)
      assert fresh.to_filename == "Casuarina - Disritmia.mp3"
    end

    test "re_resolve with no match rejects the suspect rename and leaves the track unlinked" do
      wrong = insert(:soundcharts_song, credit_name: "Wrong", name: "Song")

      track =
        insert(:track,
          tag_title: "Obscure",
          tag_artist: "Nobody",
          norm_title: "obscure",
          norm_artist: "nobody",
          filename: "old.mp3",
          rel_path: "MPB/old.mp3",
          soundcharts_song_id: wrong.id,
          sc_match_confidence: :low
        )

      {:ok, _} = NameSync.propose()
      [s] = NameSync.list_by(status: :pending)
      {:ok, flagged} = NameSync.set_reason(s, "[audit:wrong_song] suspect")

      expect(Beatgrid.Soundcharts.Mock, :search_song, fn _term -> search_response([]) end)

      assert {:ok, :no_match} = Review.re_resolve(flagged)
      assert NameSync.get(flagged.id).status == :rejected
      assert Tracks.get(track.id).soundcharts_song_id == nil
    end
  end

  describe "apply_approved/0 + Operations.undo_batch/1" do
    @tag :tmp_dir
    test "applies approved rename + classification to disk, tags the genre, all reversible",
         %{tmp_dir: root} do
      insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
      stub(Mock, :write_genre, fn _path, _genre -> :ok end)

      # --- approved rename ---
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/Old.mp3"), "a")
      song = insert(:soundcharts_song, credit_name: "Artist", name: "New")

      rtrack =
        insert(:track,
          rel_path: "MPB/Old.mp3",
          filename: "Old.mp3",
          genre_folder: "mpb",
          soundcharts_song_id: song.id,
          sc_match_confidence: :high
        )

      {:ok, _} = NameSync.propose()
      [rename] = NameSync.list_by(status: :pending)
      {:ok, _} = Review.approve(rename)

      # --- approved classification ---
      File.write!(Path.join(root, "_Inbox/song.mp3"), "audio")

      mtrack =
        insert(:track, rel_path: "_Inbox/song.mp3", filename: "song.mp3", genre_folder: nil)

      {:ok, move} =
        Organization.create_suggestion(%{
          track_id: mtrack.id,
          from_rel_path: "_Inbox/song.mp3",
          to_genre_folder: "mpb",
          source: :claude,
          confidence: 0.9
        })

      {:ok, _} = Review.approve(move)

      assert {:ok, %{batch_id: batch, applied: 2, failed: 0}} = Review.apply_approved()

      # rename applied on disk
      assert File.exists?(Path.join(root, "MPB/Artist - New.mp3"))
      assert Tracks.get(rtrack.id).filename == "Artist - New.mp3"

      # classification applied on disk + genre tag mirrored
      assert File.exists?(Path.join(root, "MPB/song.mp3"))
      moved = Tracks.get(mtrack.id)
      assert moved.genre_folder == "mpb"
      assert moved.tag_genre == "MPB"

      # three operations logged (rename, move, tag)
      assert Operations.count(batch_id: batch, status: :applied) == 3

      # --- undo the whole batch ---
      assert {:ok, %{undone: 3, failed: 0}} = Operations.undo_batch(batch)

      assert File.exists?(Path.join(root, "MPB/Old.mp3"))
      assert Tracks.get(rtrack.id).filename == "Old.mp3"
      assert File.exists?(Path.join(root, "_Inbox/song.mp3"))

      reverted = Tracks.get(mtrack.id)
      assert reverted.rel_path == "_Inbox/song.mp3"
      assert reverted.tag_genre == nil

      assert Operations.count(batch_id: batch, status: :undone) == 3
    end
  end
end
