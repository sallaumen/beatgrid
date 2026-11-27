defmodule BeatgridWeb.AjustesLiveTest do
  # async: false — edits the global Settings overrides (persistent_term cache).
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Beatgrid.Library.TrackQuery
  alias Beatgrid.Settings

  setup do
    Settings.invalidate()
    on_exit(fn -> Settings.invalidate() end)
  end

  test "renders every tunable with the default badge and the library root", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/ajustes")

    assert html =~ "Ajustes"
    assert html =~ "Alvo de loudness"
    assert html =~ "Tolerância de ganho"
    assert html =~ "Selo Ouro"
    assert html =~ "Menos vozes"
    assert html =~ "auto-arquivar"
    assert html =~ "padrão"
    assert html =~ Beatgrid.Library.library_root()
    assert has_element?(view, "h2", "Sets e discotecagem")
    assert has_element?(view, "h2", "Áudio e backup")
    assert has_element?(view, "h2", "Curadoria")
  end

  test "links preferences back to library maintenance", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ajustes")

    assert {:error, {:live_redirect, %{to: "/manutencao"}}} =
             view
             |> element("#ajustes-maintenance")
             |> render_click()
  end

  test "saving an override takes effect immediately and can be restored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ajustes")

    view
    |> form("#ajuste-target_lufs")
    |> render_submit(%{"value" => "-12.5"})

    assert Beatgrid.Loudness.target_lufs() == -12.5
    assert render(view) =~ "personalizado"
    assert has_element?(view, "#ajuste-card-target_lufs [role=status]", "salvo")

    view
    |> element("#ajuste-card-target_lufs button[phx-click=reset]")
    |> render_click()

    assert Beatgrid.Loudness.target_lufs() == -14.0
    refute render(view) =~ "personalizado"
  end

  test "an out-of-range value is rejected and changes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ajustes")

    html =
      view
      |> form("#ajuste-instrumental_min")
      |> render_submit(%{"value" => "1.5"})

    assert html =~ "inválido"
    assert has_element?(view, "#ajuste-card-instrumental_min [role=alert]", "inválido")
    assert has_element?(view, "#ajuste-instrumental_min input[aria-invalid=true]")
    assert TrackQuery.instrumental_min() == 0.1
  end

  test "hostile save/reset payloads are ignored, never crash the view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ajustes")

    render_submit(view, "save", %{"key" => "os:cmd", "value" => "1"})
    render_click(view, "reset", %{"key" => "delete"})

    assert render(view) =~ "Ajustes"
  end
end
