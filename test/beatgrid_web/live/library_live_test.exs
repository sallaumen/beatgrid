defmodule BeatgridWeb.LibraryLiveTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  setup do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    insert(:genre_folder,
      key: "forro_roots",
      display_name: "Forró Roots",
      dir_name: "Forró Roots"
    )

    :ok
  end

  test "lists present tracks and filters by genre", %{conn: conn} do
    insert(:track,
      status: :present,
      genre_folder: "mpb",
      tag_title: "Sina",
      tag_artist: "Djavan",
      norm_artist: "djavan"
    )

    insert(:track,
      status: :present,
      genre_folder: "forro_roots",
      tag_title: "Asa Branca",
      tag_artist: "Gonzaga",
      norm_artist: "gonzaga"
    )

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Biblioteca"
    assert html =~ "Sina"
    assert html =~ "Asa Branca"

    filtered = view |> element("button[phx-value-key='mpb']") |> render_click()
    assert filtered =~ "Sina"
    refute filtered =~ "Asa Branca"
  end

  test "shows the empty state when filters match nothing", %{conn: conn} do
    insert(:track,
      status: :present,
      genre_folder: "mpb",
      tag_artist: "Djavan",
      norm_artist: "djavan"
    )

    {:ok, view, _html} = live(conn, ~p"/")
    html = view |> form("header form", %{search: "zzzznomatch"}) |> render_change()
    assert html =~ "Nenhuma faixa com esses filtros"
  end
end
