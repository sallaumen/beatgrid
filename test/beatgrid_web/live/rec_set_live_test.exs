defmodule BeatgridWeb.RecSetLiveTest do
  # async: false — exporting the set writes under the (overridden) library root.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Sets

  setup %{tmp_dir: root} do
    prev = Application.get_env(:beatgrid, :library_root)
    Application.put_env(:beatgrid, :library_root, root)
    on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    :ok
  end

  defp track_with(camelot, bpm, attrs) do
    song = insert(:soundcharts_song, camelot: camelot, tempo_bpm: bpm, energy: 0.5)
    insert(:track, Keyword.merge([soundcharts_song_id: song.id], attrs))
  end

  @tag :tmp_dir
  test "build a set from a seed, append a candidate, then export to M3U", %{
    conn: conn,
    tmp_dir: root
  } do
    seed =
      track_with("8A", 120.0,
        tag_title: "Seed",
        tag_artist: "A",
        norm_title: "seed",
        norm_artist: "a"
      )

    nextt = track_with("8A", 120.5, tag_title: "Nexto", tag_artist: "B")

    {:ok, view, _html} = live(conn, ~p"/set")

    view |> element("button[phx-click=new_set]", "Novo set") |> render_click()

    # pick the seed via search, then append it
    view |> form("#seed-search", %{q: "Seed"}) |> render_change()
    view |> element("button[phx-click=append][phx-value-track='#{seed.id}']") |> render_click()

    # the harmonic candidate shows up — append it to the chain
    html =
      view |> element("button[phx-click=append][phx-value-track='#{nextt.id}']") |> render_click()

    assert html =~ "Seed"
    assert html =~ "Nexto"

    # the set persisted with both tracks, in order
    [set] = Sets.list()
    assert Enum.map(Sets.tracks(set), & &1.tag_title) == ["Seed", "Nexto"]

    # export writes the .m3u under _Sets
    export_html = view |> element("button[phx-click=export]") |> render_click()
    assert export_html =~ "exportado"
    assert File.exists?(Path.join([root, "_Sets", "Novo set.m3u"]))
  end
end
