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
  end
end
