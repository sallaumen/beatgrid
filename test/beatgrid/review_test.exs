defmodule Beatgrid.ReviewTest do
  # async: false — apply_approved/0 touches disk and overrides :library_root.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Library.{NameSync, RenameSuggestion, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Organization
  alias Beatgrid.Review
  alias Beatgrid.Soundcharts.Response
  alias Beatgrid.Tagging.Mock

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
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
      t_1 = insert(:track, rel_path: "_Inbox/a.mp3", filename: "a.mp3")
      t_2 = insert(:track, rel_path: "_Inbox/b.mp3", filename: "b.mp3")

      {:ok, high} =
        Organization.create_suggestion(%{
          track_id: t_1.id,
          from_rel_path: "_Inbox/a.mp3",
          to_genre_folder: "mpb",
          source: :claude,
          confidence: 0.95
        })

      {:ok, low} =
        Organization.create_suggestion(%{
          track_id: t_2.id,
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

  describe "apply_selected/1" do
    test "with no ids applies nothing" do
      assert {:ok, %{applied: 0, failed: 0}} = Review.apply_selected([])
    end

    @tag :tmp_dir
    test "applies only the chosen suggestions, leaving the rest pending", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/A.mp3"), "a")
      File.write!(Path.join(root, "MPB/B.mp3"), "b")

      s_1 = insert(:soundcharts_song, credit_name: "Art", name: "One")
      s_2 = insert(:soundcharts_song, credit_name: "Art", name: "Two")

      insert(:track,
        rel_path: "MPB/A.mp3",
        filename: "A.mp3",
        genre_folder: "mpb",
        soundcharts_song_id: s_1.id,
        sc_match_confidence: :high
      )

      insert(:track,
        rel_path: "MPB/B.mp3",
        filename: "B.mp3",
        genre_folder: "mpb",
        soundcharts_song_id: s_2.id,
        sc_match_confidence: :high
      )

      {:ok, _} = NameSync.propose()
      [chosen, other] = NameSync.list_by(status: :pending) |> Enum.sort_by(& &1.from_filename)

      assert {:ok, %{applied: 1, failed: 0}} = Review.apply_selected([chosen.id])

      assert NameSync.get(chosen.id).status == :applied
      assert NameSync.get(other.id).status == :pending
      assert File.exists?(Path.join(root, "MPB/Art - One.mp3"))
      assert File.exists?(Path.join(root, "MPB/B.mp3"))
    end
  end

  describe "suggestions_for_scope/1 + reevaluate_chunk/1" do
    import Mox
    setup :verify_on_exit!

    defp pending_rename(attrs) do
      song = insert(:soundcharts_song, credit_name: "Caetano Veloso", name: "Cajuína")
      n = :erlang.unique_integer([:positive])
      filename = "Cajuina-#{n}.mp3"
      rel_path = "_Inbox/#{filename}"

      track =
        insert(
          :track,
          Keyword.merge(
            [
              status: :present,
              tag_title: "Cajuina",
              filename: filename,
              rel_path: rel_path,
              soundcharts_song_id: song.id
            ],
            attrs[:track] || []
          )
        )

      {:ok, sug} =
        %RenameSuggestion{}
        |> RenameSuggestion.changeset(
          Map.merge(
            %{
              track_id: track.id,
              from_rel_path: track.rel_path,
              from_filename: track.filename,
              to_filename: "Caetano Veloso - Cajuína.mp3",
              status: :pending
            },
            attrs[:sug] || %{}
          )
        )
        |> Repo.insert()

      {track, sug}
    end

    test "unevaluated scope returns only pending suggestions without a rationale" do
      {_t_1, s_1} = pending_rename(sug: %{rationale: nil})
      {_t_2, _s_2} = pending_rename(sug: %{rationale: "already evaluated"})

      ids =
        Review.suggestions_for_scope(%{"scope" => "unevaluated"}) |> Enum.map(& &1.id)

      assert ids == [s_1.id]
    end

    test "folder scope filters by the track's genre_folder" do
      {_t_1, s_1} = pending_rename(track: [genre_folder: "forro_roots"])
      {_t_2, _s_2} = pending_rename(track: [genre_folder: "mpb"])

      ids =
        Review.suggestions_for_scope(%{"scope" => "folder", "folder" => "forro_roots"})
        |> Enum.map(& &1.id)

      assert ids == [s_1.id]
    end

    test "reevaluate_chunk re-evaluates a rejected suggestion and resets it to pending" do
      {track, sug} =
        pending_rename(track: [genre_folder: "forro_roots"], sug: %{status: :rejected})

      expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
        {:ok,
         %{
           "resolutions" => [
             %{
               "index" => 1,
               "same_recording" => false,
               "artist" => "Forró In The Dark",
               "title" => "Cajuína",
               "confidence" => 0.7,
               "rationale" => "versão forró"
             }
           ]
         }}
      end)

      assert 1 =
               Review.reevaluate_chunk([
                 %{sug | track: Tracks.get_with_song(track.id)}
               ])

      reloaded = Repo.get(RenameSuggestion, sug.id)
      assert reloaded.status == :pending
      assert reloaded.to_filename == "Forró In The Dark - Cajuína.mp3"
      assert reloaded.rationale =~ "forró"
    end
  end

  describe "reevaluate via scope one" do
    import Mox
    setup :verify_on_exit!

    test "updates the suggestion + art flag from the AI verdict, no Soundcharts call" do
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
          tag_title: "Cajuina",
          filename: "Cajuina.mp3",
          rel_path: "_Inbox/Cajuina.mp3",
          soundcharts_song_id: song.id,
          sc_match_confidence: :low
        )

      {:ok, sug} =
        %RenameSuggestion{}
        |> RenameSuggestion.changeset(%{
          track_id: track.id,
          from_rel_path: track.rel_path,
          from_filename: track.filename,
          to_filename: "Caetano Veloso - Cajuína.mp3",
          confidence: :low,
          status: :pending
        })
        |> Repo.insert()

      expect(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
        {:ok,
         %{
           "resolutions" => [
             %{
               "index" => 1,
               "same_recording" => false,
               "artist" => "Forró In The Dark",
               "title" => "Cajuína",
               "confidence" => 0.7,
               "rationale" => "versão forró"
             }
           ]
         }}
      end)

      suggestions = Review.suggestions_for_scope(%{"scope" => "one", "id" => sug.id})
      assert 1 = Review.reevaluate_chunk(suggestions)

      reloaded = Repo.get(RenameSuggestion, sug.id)
      assert reloaded.to_filename == "Forró In The Dark - Cajuína.mp3"
      assert reloaded.rationale =~ "forró"
      assert reloaded.status == :pending
      assert Tracks.get(track.id).sc_art_trusted == false
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
