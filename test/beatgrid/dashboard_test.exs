defmodule Beatgrid.DashboardTest do
  use Beatgrid.DataCase, async: false
  use Oban.Testing, repo: Beatgrid.Repo

  import Beatgrid.Factory

  alias Beatgrid.Dashboard
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Operations
  alias Beatgrid.Repertoire

  alias Beatgrid.Workers.{
    AnalyzeWorker,
    EnrichWorker,
    ExpandWorker,
    GainApplyWorker,
    MarkerAnalyzeWorker,
    RecommendWorker
  }

  test "snapshot returns the dashboard read model with selected gaps" do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    insert(:genre_folder, key: "roots", display_name: "Roots", dir_name: "Roots")

    song = insert(:soundcharts_song, tempo_bpm: 120.0, release_date: ~D[1975-03-01])

    insert(:track,
      status: :present,
      genre_folder: "mpb",
      tag_artist: "Jobim",
      soundcharts_song_id: song.id,
      sc_match_confidence: :high
    )

    insert(:recommendation,
      artist: "Elis Regina",
      song: "Aguas de Marco",
      genre_folder: "mpb",
      source: :gaps,
      status: :new
    )

    insert(:recommendation,
      artist: "Dominguinhos",
      song: "Eu So Quero Um Xodo",
      genre_folder: "roots",
      source: :gaps,
      status: :new
    )

    snapshot = Dashboard.snapshot("mpb")

    assert snapshot.page_title == "Painel"
    assert snapshot.overview.total == 1
    assert snapshot.gaps_folder == "mpb"
    assert snapshot.gap_counts == %{"mpb" => 1, "roots" => 1}
    assert Enum.map(snapshot.recs, & &1.artist) == ["Elis Regina"]
    assert Enum.map(snapshot.artists, &elem(&1, 0)) == ["Jobim"]
  end

  test "run(:analyze_library) enqueues pending analysis and returns a progress patch" do
    track = insert(:track, status: :present, analyzed_at: nil)

    assert {:ok, patch} = Dashboard.run(:analyze_library)

    assert patch.analysis == %{analyzed: 0, total: 1}
    assert patch.analysis_note =~ "1 faixa"
    assert_enqueued(worker: AnalyzeWorker, args: %{track_id: track.id})
  end

  test "run(:map_markers) enqueues unmapped marker analysis" do
    track = insert(:track, status: :present, rel_path: "u1.mp3", cue_points: [])

    assert {:ok, patch} = Dashboard.run(:map_markers)

    assert patch.markers_unmapped == 1
    assert patch.markers_note =~ "Mapeando marcadores de 1"
    assert_enqueued(worker: MarkerAnalyzeWorker, args: %{track_id: track.id})
  end

  test "run(:apply_gain) enqueues eligible gain application with one batch id" do
    eligible =
      insert(:track,
        status: :present,
        loudness_lufs: -20.0,
        true_peak_dbtp: -8.0,
        loudness_attempted_at: ~U[2026-01-01 00:00:00Z]
      )

    assert {:ok, patch} = Dashboard.run(:apply_gain)

    assert patch.gain_pending == 1
    assert patch.gain_undo_batch
    assert patch.loudness_note == "1 track(s) queued for gain application."
    assert_enqueued(worker: GainApplyWorker, args: %{track_id: eligible.id})
  end

  test "run({:restore_gain_backup, nil}) returns the no-backup note" do
    assert {:ok, patch} = Dashboard.run({:restore_gain_backup, nil})

    assert patch == %{loudness_note: "No gain backup is available to restore."}
  end

  test "run({:download_youtube, urls}) enqueues submitted URLs" do
    assert {:ok, patch} = Dashboard.run({:download_youtube, "https://y/1\nhttps://y/2"})

    assert patch.youtube_note =~ "2 na fila"
    assert_enqueued(worker: ExpandWorker, args: %{url: "https://y/1"})
    assert_enqueued(worker: ExpandWorker, args: %{url: "https://y/2"})
  end

  test "run(:enrich_youtube) enqueues the pending enrichment batch" do
    insert(:track, status: :present, genre_folder: nil, soundcharts_song_id: nil)

    assert {:ok, patch} = Dashboard.run(:enrich_youtube)

    assert patch == %{enrich: %{status: :queued}, youtube_note: nil}
    assert_enqueued(worker: EnrichWorker, args: %{scope: "pending"})
  end

  test "run({:fetch_gaps, folder}) enqueues a folder recommendation job" do
    assert {:ok, patch} = Dashboard.run({:fetch_gaps, "mpb"})

    assert patch == %{recommending?: true}
    assert_enqueued(worker: RecommendWorker, args: %{scope: "folder", folder: "mpb"})
  end

  test "run({:download_recommendation, id}, folder: folder, current_note: note) imports and reloads gaps" do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    rec =
      insert(:recommendation,
        artist: "Tim Maia",
        song: "Azul da Cor do Mar",
        youtube_query: "Tim Maia Azul da Cor do Mar",
        genre_folder: "mpb",
        source: :gaps,
        status: :new
      )

    assert {:ok, patch} =
             Dashboard.run({:download_recommendation, rec.id},
               folder: "mpb",
               current_note: "old note"
             )

    assert patch.youtube_note =~ "Tim Maia"
    assert Repertoire.get_recommendation(rec.id).status == :imported
    assert Enum.map(patch.recs, & &1.id) == [rec.id]
    assert_enqueued(worker: ExpandWorker, args: %{url: "ytsearch1:Tim Maia Azul da Cor do Mar"})
  end

  @tag :tmp_dir
  test "run({:restore_gain_backup, batch_id}) delegates to operations and refreshes loudness" do
    previous = Application.get_env(:beatgrid, :library_root)
    Application.put_env(:beatgrid, :library_root, tmp_dir())
    on_exit(fn -> Application.put_env(:beatgrid, :library_root, previous) end)

    root = Application.fetch_env!(:beatgrid, :library_root)
    rel_path = "_Inbox/restorable.mp3"
    backup_rel = "_Backups/Gain/batch/_Inbox/restorable.mp3"
    write_file(root, rel_path, "gain-applied-audio")
    write_file(root, backup_rel, "original-audio")

    track =
      insert(:track,
        status: :present,
        rel_path: rel_path,
        loudness_lufs: -14.0,
        true_peak_dbtp: -2.0,
        gain_applied_db: 6.0,
        gain_applied_at: ~U[2026-01-01 00:00:00Z]
      )

    batch_id = Ecto.UUID.generate()

    {:ok, _op} =
      Operations.record(%{
        track_id: track.id,
        kind: :gain,
        from: "6.0",
        to: backup_rel,
        batch_id: batch_id
      })

    Beatgrid.Audio.LoudnessMock
    |> Mox.expect(:measure, fn path ->
      assert File.read!(path) == "original-audio"
      {:ok, %{lufs: -20.0, true_peak: -8.0, lra: 4.0}}
    end)

    assert {:ok, patch} = Dashboard.run({:restore_gain_backup, batch_id})

    assert patch.loudness_note == "1 gain backup(s) restored."
    assert File.read!(Path.join(root, rel_path)) == "original-audio"
    assert Tracks.get(track.id).gain_applied_at == nil
  end

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "beatgrid-dashboard-test-#{System.unique_integer([:positive])}")
  end

  defp write_file(root, rel_path, contents) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
