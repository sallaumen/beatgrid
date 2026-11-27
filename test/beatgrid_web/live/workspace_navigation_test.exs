defmodule BeatgridWeb.WorkspaceNavigationTest do
  use BeatgridWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "one labeled destination per workflow in both menu sizes", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    groups = [
      {"Coleção", ~w(/ /importados /painel)},
      {"Curadoria", ~w(/revisao /dedup /generos /resgate)},
      {"Sets e palco", ~w(/set /sets-online /discotecagem)},
      {"Sistema", ~w(/jobs /manutencao /ajustes)}
    ]

    for {group, paths} <- groups, path <- paths do
      assert has_element?(
               view,
               "#app-destinations [role=group][aria-label='#{group}'] a[href='#{path}']"
             )
    end

    assert has_element?(view, "#app-destinations a[aria-current=page]", "Biblioteca")
    assert has_element?(view, "a[href='#workspace-content']", "Ir para o conteúdo")
    assert has_element?(view, "#app-navigation[phx-hook]")

    assert has_element?(
             view,
             "#mobile-nav-toggle[aria-controls=app-destinations][aria-expanded=false]"
           )
  end

  test "navigating to another workspace moves the current-page marker", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/ajustes")
    assert has_element?(view, "#app-destinations a[aria-current=page][href='/ajustes']")

    {:ok, destination, _} =
      view
      |> element("#app-destinations a[href='/jobs']")
      |> render_click()
      |> follow_redirect(conn, ~p"/jobs")

    assert has_element?(destination, "#app-destinations a[aria-current=page][href='/jobs']")
    refute has_element?(destination, "#app-destinations a[aria-current=page][href='/ajustes']")
  end
end
