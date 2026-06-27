defmodule BeatgridWeb.GenresLiveTest do
  # async: false — "Preencher com IA" runs a start_async task that talks to the
  # (globally stubbed) AI mock and the shared sandbox.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.GenreFolders

  setup :set_mox_global

  test "lists folders and saves an edited description", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "old")

    {:ok, view, html} = live(conn, ~p"/generos")
    assert html =~ "Gêneros"
    assert html =~ "MPB"
    assert html =~ "old"

    view
    |> form("#folder-mpb", %{description: "Songwriter MPB; voz+violão."})
    |> render_submit()

    assert GenreFolders.get_by_key("mpb").description == "Songwriter MPB; voz+violão."
  end

  test "creating via the form adds a folder", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/generos")

    html =
      view
      |> form("#new-genre", %{display_name: "Forró Pé de Serra", color: "#abc123"})
      |> render_submit()

    assert html =~ "Forró Pé de Serra"

    folder = GenreFolders.get_by_key("forro_pe_de_serra")
    assert folder
    assert folder.display_name == "Forró Pé de Serra"
    assert folder.dir_name == "Forró Pé de Serra"
    assert folder.color == "#abc123"
  end

  test "deleting an empty folder removes it", %{conn: conn} do
    insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")

    {:ok, view, html} = live(conn, ~p"/generos")
    assert html =~ "Samba"

    html =
      view
      |> element(~s(button[phx-click="delete_genre"][phx-value-key="samba"]))
      |> render_click()

    refute html =~ "Samba"
    assert GenreFolders.get_by_key("samba") == nil
  end

  test "deleting an in-use folder shows the in-use toast and keeps it", %{conn: conn} do
    insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")
    insert(:track, genre_folder: "samba", status: :present)

    {:ok, view, _html} = live(conn, ~p"/generos")

    # the delete control is disabled while in use; drive the event directly
    html = render_click(view, "delete_genre", %{"key" => "samba"})

    assert html =~ "em uso"
    assert GenreFolders.get_by_key("samba")
  end

  test "Preencher com IA fills the textarea with the suggested rubric", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "")

    stub(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "description" => "Songwriter-driven Brazilian popular music.",
         "rationale" => "voz e violão no centro"
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/generos")

    view
    |> element(~s(button[phx-click="suggest_description"][phx-value-key="mpb"]))
    |> render_click()

    html = render_async(view)

    assert html =~ "Songwriter-driven Brazilian popular music."
  end
end
