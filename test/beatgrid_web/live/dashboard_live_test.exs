defmodule BeatgridWeb.DashboardLiveTest do
  # async: false — the gaps flow runs an async task that talks to the (globally
  # stubbed) AI mock and the shared sandbox.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  setup :set_mox_global

  test "shows headline KPIs and the genre / artist distributions", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    song = insert(:soundcharts_song, tempo_bpm: 120.0, release_date: ~D[1975-03-01])

    insert(:track,
      status: :present,
      genre_folder: "mpb",
      tag_artist: "Jobim",
      soundcharts_song_id: song.id,
      sc_match_confidence: :high
    )

    insert(:track, status: :present, genre_folder: "mpb", tag_artist: "Gil")

    {:ok, _view, html} = live(conn, ~p"/painel")

    assert html =~ "Painel"
    assert html =~ "Total"
    assert html =~ "Resolvidas"
    assert html =~ "MPB"
    assert html =~ "Jobim"
    assert html =~ "1970s"
  end

  test "fetching repertoire gaps renders the AI suggestions", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    stub(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "gaps" => [
           %{"artist" => "Elis Regina", "song" => "Águas de Março", "reason" => "essencial MPB"}
         ]
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/painel")

    view |> element("button[phx-click=fetch_gaps]") |> render_click()
    html = render_async(view)

    assert html =~ "Elis Regina"
    assert html =~ "Águas de Março"
    assert html =~ "essencial MPB"
  end
end
