defmodule BeatgridWeb.GenresLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.GenreFolders

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
end
