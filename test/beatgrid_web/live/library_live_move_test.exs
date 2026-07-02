defmodule BeatgridWeb.LibraryLiveMoveTest do
  # async: false — the row ⋯ menu and batch bar drive real on-disk moves
  # (override :library_root) and the move's Tagging write goes through the global
  # Mox stub, so the LiveView process must see it (set_mox_global).
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks

  setup :set_mox_global
  setup :isolate_library_root

  setup tags do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    insert(:genre_folder, key: "forro", display_name: "Forró", dir_name: "Forró")

    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
    end

    # The genre tag write goes through the Tagging.Writer port (mocked, 2-arity).
    stub(Beatgrid.Tagging.Mock, :write_genre, fn _path, _genre -> :ok end)
    :ok
  end

  describe "row ⋯ menu" do
    @tag :tmp_dir
    test "Mover para moves the track on disk, updates the row, and shows an undo toast", %{
      conn: conn,
      tmp_dir: root
    } do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/x.mp3"), "bytes")

      track =
        insert(:track,
          status: :present,
          rel_path: "MPB/x.mp3",
          filename: "x.mp3",
          genre_folder: "mpb",
          tag_title: "Mover-me",
          tag_artist: "Artista"
        )

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("button[phx-value-id='#{track.id}'][phx-click='row_menu_toggle']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='move_track'][phx-value-to='forro']")
        |> render_click()

      assert Tracks.get(track.id).genre_folder == "forro"
      assert File.exists?(Path.join(root, "Forró/x.mp3"))
      refute File.exists?(Path.join(root, "MPB/x.mp3"))
      # the undo affordance appears
      assert html =~ "Desfazer"
    end

    test "Parecidas pre-fills the filters around a track and narrows the list", %{conn: conn} do
      song = insert(:soundcharts_song, camelot: "8A", energy: 0.6)

      ref =
        insert(:track,
          status: :present,
          genre_folder: "mpb",
          tag_title: "Referência",
          tag_artist: "Ref",
          norm_artist: "ref",
          soundcharts_song_id: song.id
        )

      neighbor_song = insert(:soundcharts_song, camelot: "9A", energy: 0.6)

      insert(:track,
        status: :present,
        genre_folder: "mpb",
        tag_title: "Vizinha",
        tag_artist: "Viz",
        norm_artist: "viz",
        soundcharts_song_id: neighbor_song.id
      )

      far_song = insert(:soundcharts_song, camelot: "3B", energy: 0.1)

      insert(:track,
        status: :present,
        genre_folder: "mpb",
        tag_title: "Distante",
        tag_artist: "Dist",
        norm_artist: "dist",
        soundcharts_song_id: far_song.id
      )

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("button[phx-value-id='#{ref.id}'][phx-click='row_menu_toggle']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='similar_to'][phx-value-track_id='#{ref.id}']")
        |> render_click()

      # the reference + its harmonic neighbor stay; the far/low-energy one drops
      assert html =~ "Referência"
      assert html =~ "Vizinha"
      refute html =~ "Distante"
    end
  end

  describe "batch select mode" do
    @tag :tmp_dir
    test "Mover N moves every selected track under one undoable batch", %{
      conn: conn,
      tmp_dir: root
    } do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/a.mp3"), "a")
      File.write!(Path.join(root, "MPB/b.mp3"), "b")

      a =
        insert(:track,
          status: :present,
          rel_path: "MPB/a.mp3",
          filename: "a.mp3",
          genre_folder: "mpb",
          tag_title: "A",
          tag_artist: "AA"
        )

      b =
        insert(:track,
          status: :present,
          rel_path: "MPB/b.mp3",
          filename: "b.mp3",
          genre_folder: "mpb",
          tag_title: "B",
          tag_artist: "BB"
        )

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("button[phx-click='toggle_select_mode']") |> render_click()

      view
      |> element("button[phx-click='toggle_select'][phx-value-id='#{a.id}']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_select'][phx-value-id='#{b.id}']")
      |> render_click()

      html =
        view
        |> form("#batch-move", %{folder: "forro"})
        |> render_change()

      assert Tracks.get(a.id).genre_folder == "forro"
      assert Tracks.get(b.id).genre_folder == "forro"
      assert html =~ "Desfazer"
    end

    test "Avaliar N rates every selected track", %{conn: conn} do
      a = insert(:track, status: :present, tag_title: "A", tag_artist: "AA", rating: nil)
      b = insert(:track, status: :present, tag_title: "B", tag_artist: "BB", rating: nil)

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("button[phx-click='toggle_select_mode']") |> render_click()

      view
      |> element("button[phx-click='toggle_select'][phx-value-id='#{a.id}']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_select'][phx-value-id='#{b.id}']")
      |> render_click()

      view
      |> element("button[phx-click='rate_selected'][phx-value-rating='8']")
      |> render_click()

      assert Tracks.get(a.id).rating == 8
      assert Tracks.get(b.id).rating == 8
    end

    @tag :tmp_dir
    test "Desfazer reverts the last batch move", %{conn: conn, tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "MPB"))
      File.write!(Path.join(root, "MPB/x.mp3"), "bytes")

      track =
        insert(:track,
          status: :present,
          rel_path: "MPB/x.mp3",
          filename: "x.mp3",
          genre_folder: "mpb",
          tag_title: "X",
          tag_artist: "XX"
        )

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("button[phx-value-id='#{track.id}'][phx-click='row_menu_toggle']")
      |> render_click()

      view
      |> element("button[phx-click='move_track'][phx-value-to='forro']")
      |> render_click()

      assert Tracks.get(track.id).genre_folder == "forro"

      view |> element("button[phx-click='undo_move']") |> render_click()

      assert Tracks.get(track.id).genre_folder == "mpb"
      assert File.exists?(Path.join(root, "MPB/x.mp3"))
      refute File.exists?(Path.join(root, "Forró/x.mp3"))
    end
  end
end
