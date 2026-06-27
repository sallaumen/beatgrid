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

  test "library rows can play in the global player and still link to the track", %{conn: conn} do
    track = insert(:track, status: :present, tag_title: "Sina", tag_artist: "Djavan")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "beatgrid:play"
    assert html =~ "#player-audio"
    assert html =~ "/track/#{track.id}"
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

  describe "sortable headers" do
    test "clicking the BPM header sorts the rows by effective bpm", %{conn: conn} do
      fast_song = insert(:soundcharts_song, tempo_bpm: 150.0)
      slow_song = insert(:soundcharts_song, tempo_bpm: 90.0)

      insert(:track,
        status: :present,
        tag_title: "Fast",
        tag_artist: "ZZ",
        norm_artist: "zz",
        norm_title: "fast",
        soundcharts_song_id: fast_song.id
      )

      insert(:track,
        status: :present,
        tag_title: "Slow",
        tag_artist: "AA",
        norm_artist: "aa",
        norm_title: "slow",
        soundcharts_song_id: slow_song.id
      )

      {:ok, view, html} = live(conn, ~p"/")
      # default sort is by artist asc → "Slow" (AA) before "Fast" (ZZ)
      assert before?(html, "Slow", "Fast")

      # clicking BPM sorts ascending → slow (90) before fast (150)
      asc = view |> element("button[phx-value-by='bpm']") |> render_click()
      assert before?(asc, "Slow", "Fast")

      # clicking BPM again toggles to descending → fast (150) before slow (90)
      desc = view |> element("button[phx-value-by='bpm']") |> render_click()
      assert before?(desc, "Fast", "Slow")
    end
  end

  describe "extended filter rail" do
    test "a Tom filter with compatibles narrows to harmonic neighbors", %{conn: conn} do
      song_8a = insert(:soundcharts_song, camelot: "8A")
      song_3b = insert(:soundcharts_song, camelot: "3B")

      insert(:track,
        status: :present,
        tag_title: "Keep",
        tag_artist: "Keeper",
        norm_artist: "keeper",
        soundcharts_song_id: song_8a.id
      )

      insert(:track,
        status: :present,
        tag_title: "Drop",
        tag_artist: "Dropper",
        norm_artist: "dropper",
        soundcharts_song_id: song_3b.id
      )

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#library-filters", %{camelot: "8A", camelot_compatible: "on"})
        |> render_change()

      assert html =~ "Keep"
      refute html =~ "Drop"
    end

    test "an energy minimum narrows to high-energy tracks", %{conn: conn} do
      hot = insert(:soundcharts_song, energy: 0.8)
      cold = insert(:soundcharts_song, energy: 0.2)

      insert(:track,
        status: :present,
        tag_title: "Hot",
        tag_artist: "Heater",
        norm_artist: "heater",
        soundcharts_song_id: hot.id
      )

      insert(:track,
        status: :present,
        tag_title: "Cold",
        tag_artist: "Cooler",
        norm_artist: "cooler",
        soundcharts_song_id: cold.id
      )

      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> form("#library-filters", %{energy_min: "50"}) |> render_change()

      assert html =~ "Hot"
      refute html =~ "Cold"
    end

    test "a maximum rating narrows to low-rated tracks", %{conn: conn} do
      insert(:track,
        status: :present,
        tag_title: "Cheap",
        tag_artist: "Low",
        norm_artist: "low",
        rating: 3
      )

      insert(:track,
        status: :present,
        tag_title: "Pricey",
        tag_artist: "High",
        norm_artist: "high",
        rating: 9
      )

      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> form("#library-filters", %{rating_max: "5"}) |> render_change()

      assert html =~ "Cheap"
      refute html =~ "Pricey"
    end

    test "the 'só não classificadas' toggle shows only unfiled tracks", %{conn: conn} do
      insert(:track,
        status: :present,
        genre_folder: "mpb",
        tag_title: "Filed",
        tag_artist: "Sorted",
        norm_artist: "sorted"
      )

      insert(:track,
        status: :present,
        genre_folder: nil,
        tag_title: "Loose",
        tag_artist: "Inbox",
        norm_artist: "inbox"
      )

      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element("button[phx-click='toggle_unclassified']") |> render_click()

      assert html =~ "Loose"
      refute html =~ "Filed"
    end
  end

  test "highlights and shows a spinning disc on the currently-playing track", %{conn: conn} do
    a = insert(:track, status: :present, tag_artist: "A", tag_title: "Aaa")

    {:ok, view, _html} = live(conn, ~p"/")
    refute render(view) =~ "now-playing-disc"

    send(view.pid, {:now_playing, %{track_id: a.id, set_id: nil}})
    html = render(view)

    assert html =~ "now-playing-disc"
    assert html =~ "ring-primary/40"
  end

  # True if `a` appears before `b` in the rendered HTML.
  defp before?(html, a, b) do
    ia = :binary.match(html, a) |> elem(0)
    ib = :binary.match(html, b) |> elem(0)
    ia < ib
  end
end
