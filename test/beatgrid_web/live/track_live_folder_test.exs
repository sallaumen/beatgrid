defmodule BeatgridWeb.TrackLiveFolderTest do
  # async: false — the folder change is a real move on disk + a global-mox tag write.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.Tracks

  setup :set_mox_global
  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir], do: File.mkdir_p!(Path.join(root, "MPB"))
    stub(Beatgrid.Tagging.Mock, :write_genre, fn _path, _genre -> :ok end)
    :ok
  end

  @tag :tmp_dir
  test "shows the current folder and moves the track to another one", %{conn: conn, tmp_dir: root} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    insert(:genre_folder, key: "forro", display_name: "Forró", dir_name: "Forró")
    File.write!(Path.join(root, "MPB/x.mp3"), "bytes")

    track =
      insert(:track,
        status: :present,
        rel_path: "MPB/x.mp3",
        filename: "x.mp3",
        genre_folder: "mpb",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")

    # the current folder is always shown as a select, with both folders offered
    assert html =~ "Pasta"
    assert has_element?(view, "form[phx-change=change_folder] select option[value='mpb']")
    assert has_element?(view, "form[phx-change=change_folder] select option[value='forro']")

    view
    |> form("form[phx-change=change_folder]", %{"folder" => "forro"})
    |> render_change()

    moved = Tracks.get(track.id)
    assert moved.genre_folder == "forro"
    assert moved.rel_path == "Forró/x.mp3"
    assert File.exists?(Path.join(root, "Forró/x.mp3"))
    refute File.exists?(Path.join(root, "MPB/x.mp3"))
  end

  @tag :tmp_dir
  test "reselecting the same folder is a no-op (no move, no error)", %{conn: conn, tmp_dir: root} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    File.write!(Path.join(root, "MPB/x.mp3"), "bytes")

    track =
      insert(:track,
        status: :present,
        rel_path: "MPB/x.mp3",
        filename: "x.mp3",
        genre_folder: "mpb",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    view
    |> form("form[phx-change=change_folder]", %{"folder" => "mpb"})
    |> render_change()

    assert Tracks.get(track.id).rel_path == "MPB/x.mp3"
    assert File.exists?(Path.join(root, "MPB/x.mp3"))
  end
end
