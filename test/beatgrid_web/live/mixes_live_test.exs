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

  test "lists investigation metadata for imported mixes", %{conn: conn} do
    track = insert(:track, status: :present)

    mix =
      insert(:mix,
        title: "Long Forró Research",
        dj: "DJ Roots",
        source_url: "https://soundcloud.com/dj-roots/long-forro-research",
        duration_ms: 10_800_000,
        status: :ready
      )

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      end_ms: 120_000,
      matched_track_id: track.id
    )

    insert(:mix_segment, mix: mix, position: 1, start_ms: 120_000, end_ms: 240_000)

    {:ok, _view, html} = live(conn, ~p"/sets-online")

    assert html =~ "Long Forró Research"
    assert html =~ "DJ Roots"
    assert html =~ "soundcloud.com/dj-roots/long-forro-research"
    assert html =~ "3:00:00"
    assert html =~ "2 tracks"
    assert html =~ "50% library"
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

  test "imports a youtube url and shows source badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sets-online")
    render_submit(element(view, "#mix-import-form"), %{"url" => "https://youtu.be/a93fldI5DSU"})
    html = render(view)
    assert html =~ "YT"
    assert html =~ "baixando"
  end

  test "rejects an unsupported url with a friendly message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sets-online")
    render_submit(element(view, "#mix-import-form"), %{"url" => "https://vimeo.com/1"})
    assert render(view) =~ "YouTube ou SoundCloud"
  end
end
