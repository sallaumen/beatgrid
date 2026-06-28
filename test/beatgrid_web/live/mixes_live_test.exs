defmodule BeatgridWeb.MixesLiveTest do
  use BeatgridWeb.ConnCase, async: true, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  test "lists mixes and renders the import box", %{conn: conn} do
    insert(:mix, title: "Awakenings 2024", dj: "DJ X", status: :ready)

    {:ok, _view, html} = live(conn, ~p"/sets-online")

    assert html =~ "Sets online"
    assert html =~ "Awakenings 2024"
    assert html =~ "DJ X"
    assert html =~ "Importar"
  end

  test "submitting a SoundCloud URL enqueues a download and shows the new mix", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sets-online")

    html =
      view
      |> form("#mix-import-form", %{url: "https://soundcloud.com/dj/awesome-set"})
      |> render_submit()

    assert_enqueued(worker: Beatgrid.Workers.MixDownloadWorker)
    assert html =~ "soundcloud.com/dj/awesome-set" or html =~ "Baixando"
  end
end
