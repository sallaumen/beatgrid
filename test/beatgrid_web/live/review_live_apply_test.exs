defmodule BeatgridWeb.ReviewLiveApplyTest do
  # async: false — drives the async apply/undo, which touches disk, the shared
  # sandbox, and the (globally stubbed) Tagging mock.
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.{NameSync, Tracks}
  alias Beatgrid.{Operations, Organization}

  setup :set_mox_global

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "_Inbox"))
    prev = Application.get_env(:beatgrid, :library_root)
    Application.put_env(:beatgrid, :library_root, root)
    on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    :ok
  end

  @tag :tmp_dir
  test "approve in the UI, apply to disk, then undo from the toast", %{conn: conn, tmp_dir: root} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    stub(Beatgrid.Tagging.Mock, :write_genre, fn _path, _genre -> :ok end)

    # an approvable rename
    File.mkdir_p!(Path.join(root, "MPB"))
    File.write!(Path.join(root, "MPB/Old.mp3"), "a")
    song = insert(:soundcharts_song, credit_name: "Artist", name: "New")

    track =
      insert(:track,
        rel_path: "MPB/Old.mp3",
        filename: "Old.mp3",
        genre_folder: "mpb",
        soundcharts_song_id: song.id,
        sc_match_confidence: :high
      )

    {:ok, _} = NameSync.propose()
    [rename] = NameSync.list_by(status: :pending)

    # an approvable classification
    File.write!(Path.join(root, "_Inbox/song.mp3"), "audio")
    mtrack = insert(:track, rel_path: "_Inbox/song.mp3", filename: "song.mp3", genre_folder: nil)

    {:ok, move} =
      Organization.create_suggestion(%{
        track_id: mtrack.id,
        from_rel_path: "_Inbox/song.mp3",
        to_genre_folder: "mpb",
        source: :claude,
        confidence: 0.9
      })

    {:ok, view, _html} = live(conn, ~p"/revisao")

    # mark the rename (Renomeações tab), then the classification (Classificação tab)
    view
    |> element("button[phx-click=toggle_select][phx-value-id='#{rename.id}']")
    |> render_click()

    view |> element("button[phx-value-tab=classifications]") |> render_click()

    view
    |> element("button[phx-click=toggle_select][phx-value-id='#{move.id}']")
    |> render_click()

    # apply to disk (async)
    apply_html =
      view
      |> element("button[phx-click=apply]")
      |> render_click()
      |> then(fn _ -> render_async(view) end)

    assert apply_html =~ "aplicadas no disco"

    assert File.exists?(Path.join(root, "MPB/Artist - New.mp3"))
    assert Tracks.get(track.id).filename == "Artist - New.mp3"
    assert Tracks.get(mtrack.id).rel_path == "MPB/song.mp3"
    assert Operations.count(status: :applied) == 3

    # undo from the toast (async)
    view |> element("button[phx-click=undo]") |> render_click()
    render_async(view)

    assert File.exists?(Path.join(root, "MPB/Old.mp3"))
    assert Tracks.get(track.id).filename == "Old.mp3"
    assert Tracks.get(mtrack.id).rel_path == "_Inbox/song.mp3"
    assert NameSync.get(rename.id).status == :undone
    assert Operations.count(status: :undone) == 3
  end

  @tag :tmp_dir
  test "quarantine from the auditoria tab moves the file off the library", %{
    conn: conn,
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
    [r] = NameSync.list_by(status: :pending)
    {:ok, _} = NameSync.set_reason(r, "[audit:verify] soundcharts: A - B")

    {:ok, view, _html} = live(conn, ~p"/revisao")
    view |> element("button[phx-value-tab=auditoria]") |> render_click()
    view |> element("button[phx-click=quarantine][phx-value-id='#{r.id}']") |> render_click()

    assert File.exists?(Path.join(root, "_Quarantine/bad.mp3"))
    refute File.exists?(Path.join(root, "MPB/bad.mp3"))
    assert Tracks.get(track.id).status == :quarantined
    assert NameSync.get(r.id).status == :rejected
  end

  @tag :tmp_dir
  test "re-resolve from the auditoria tab enqueues a worker and updates on completion (no-match path)",
       %{conn: conn} do
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
    [r] = NameSync.list_by(status: :pending)
    {:ok, _} = NameSync.set_reason(r, "[audit:wrong] suspect")

    stub(Beatgrid.Soundcharts.Mock, :search_song, fn _term ->
      {:ok, %Beatgrid.Soundcharts.Response{data: [], quota_remaining: 999, status: 200}}
    end)

    {:ok, view, _html} = live(conn, ~p"/revisao")
    view |> element("button[phx-value-tab=auditoria]") |> render_click()

    html =
      view |> element("button[phx-click=re_resolve][phx-value-id='#{r.id}']") |> render_click()

    # The click only enqueues — the work runs in the background worker.
    assert html =~ "Re-resolvendo no Soundcharts"
    assert_enqueued(worker: Beatgrid.Workers.ReResolveWorker, args: %{suggestion_id: r.id})

    # Run the job; its completion broadcast pushes the LiveView to refresh.
    assert :ok = perform_job(Beatgrid.Workers.ReResolveWorker, %{"suggestion_id" => r.id})

    assert render(view) =~ "Sem novo match"
    assert NameSync.get(r.id).status == :rejected
    assert Tracks.get(track.id).soundcharts_song_id == nil
  end
end
