defmodule BeatgridWeb.TrackLiveRenameTest do
  # async: false — renaming touches disk and overrides :library_root globally.
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "MPB"))
    prev = Application.get_env(:beatgrid, :library_root)
    Application.put_env(:beatgrid, :library_root, root)
    on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    %{root: root}
  end

  test "inline-renames the file on disk and can undo it", %{conn: conn, root: root} do
    File.write!(Path.join(root, "MPB/old.mp3"), "audio")

    track =
      insert(:track,
        status: :present,
        rel_path: "MPB/old.mp3",
        filename: "old.mp3",
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    # Rename via the inline pencil on the "Arquivo" field.
    view |> element(~s|button[phx-click=edit_field][phx-value-field=filename]|) |> render_click()

    html =
      view |> form("form[phx-submit=save_field]", %{value: "Novo Nome.mp3"}) |> render_submit()

    assert Tracks.get(track.id).filename == "Novo Nome.mp3"
    assert File.exists?(Path.join(root, "MPB/Novo Nome.mp3"))
    refute File.exists?(Path.join(root, "MPB/old.mp3"))
    assert html =~ "Desfazer"

    # Undo restores the original filename + the file on disk.
    view |> element("button[phx-click=undo_rename]") |> render_click()

    assert Tracks.get(track.id).filename == "old.mp3"
    assert File.exists?(Path.join(root, "MPB/old.mp3"))
    refute File.exists?(Path.join(root, "MPB/Novo Nome.mp3"))
  end

  test "renaming without an extension keeps the original one", %{conn: conn, root: root} do
    File.write!(Path.join(root, "MPB/song.mp3"), "audio")

    track =
      insert(:track,
        status: :present,
        rel_path: "MPB/song.mp3",
        filename: "song.mp3",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    view |> element(~s|button[phx-click=edit_field][phx-value-field=filename]|) |> render_click()
    view |> form("form[phx-submit=save_field]", %{value: "Sem Extensao"}) |> render_submit()

    assert Tracks.get(track.id).filename == "Sem Extensao.mp3"
    assert File.exists?(Path.join(root, "MPB/Sem Extensao.mp3"))
  end

  test "a name with a mid-string dot still keeps the audio extension", %{conn: conn, root: root} do
    File.write!(Path.join(root, "MPB/song.mp3"), "audio")

    track =
      insert(:track,
        status: :present,
        rel_path: "MPB/song.mp3",
        filename: "song.mp3",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    view |> element(~s|button[phx-click=edit_field][phx-value-field=filename]|) |> render_click()
    view |> form("form[phx-submit=save_field]", %{value: "Mr. Big - Song"}) |> render_submit()

    # Path.extname("Mr. Big - Song") is non-empty but not a real ext → append .mp3.
    assert Tracks.get(track.id).filename == "Mr. Big - Song.mp3"
    assert File.exists?(Path.join(root, "MPB/Mr. Big - Song.mp3"))
  end

  test "a traversal filename is refused and the file is left in place", %{conn: conn, root: root} do
    File.write!(Path.join(root, "MPB/song.mp3"), "audio")

    track =
      insert(:track,
        status: :present,
        rel_path: "MPB/song.mp3",
        filename: "song.mp3",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    view |> element(~s|button[phx-click=edit_field][phx-value-field=filename]|) |> render_click()

    html =
      view |> form("form[phx-submit=save_field]", %{value: "../escaped.mp3"}) |> render_submit()

    # Original file untouched, nothing escaped, and the user is told why.
    assert Tracks.get(track.id).filename == "song.mp3"
    assert File.exists?(Path.join(root, "MPB/song.mp3"))
    refute File.exists?(Path.join(root, "escaped.mp3"))
    assert html =~ "inválido"
  end
end
