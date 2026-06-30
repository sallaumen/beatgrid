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

    insert(:genre_folder,
      key: "forro_roots",
      display_name: "Forró Roots",
      dir_name: "Forró Roots"
    )

    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    insert(:genre_folder, key: "forro_mpb", display_name: "Forró MPB", dir_name: "Forró MPB")
    :ok
  end

  defp track_with(camelot, bpm, attrs) do
    song = insert(:soundcharts_song, camelot: camelot, tempo_bpm: bpm, energy: 0.5)
    insert(:track, Keyword.merge([soundcharts_song_id: song.id, status: :present], attrs))
  end

  defp new_set(view),
    do: view |> element("button[phx-click=new_set]", "Novo set") |> render_click()

  # The right-rail panels start collapsed; open one before interacting with it.
  defp open_panel(view, id),
    do: view |> element("button[phx-value-panel='#{id}']") |> render_click()

  @tag :tmp_dir
  test "build a set from search, append, play affordance, then export to M3U", %{
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
    new_set(view)
    open_panel(view, "search")

    # find and append the seed from the search panel
    view |> form("#track-search", %{q: "Seed"}) |> render_change()

    view
    |> element("#search-results button[phx-click=append][phx-value-track='#{seed.id}']")
    |> render_click()

    # search box is STILL present after the set has tracks (the old bug: it vanished)
    assert has_element?(view, "#track-search")
    # play buttons target the global player, not a local one
    assert render(view) =~ ~s(id="player-audio")
    refute render(view) =~ ~s(id="set-player")

    # the harmonic candidate shows up in the candidates panel — append it
    open_panel(view, "candidates")

    html =
      view |> element("button[phx-click=append][phx-value-track='#{nextt.id}']") |> render_click()

    assert html =~ "Seed"
    assert html =~ "Nexto"

    [set] = Sets.list()
    assert Enum.map(Sets.tracks(set), & &1.tag_title) == ["Seed", "Nexto"]

    export_html = view |> element("button[phx-click=export]") |> render_click()
    assert export_html =~ "exportado"
    assert File.exists?(Path.join([root, "_Sets", "Novo set.m3u"]))
  end

  @tag :tmp_dir
  test "choosing a target style anchors the set", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)

    view |> form("#target-style") |> render_change(%{style: "forro_roots"})

    [set] = Sets.list()
    assert set.target_style == "forro_roots"
  end

  @tag :tmp_dir
  test "filling a section appends tracks tagged with the role", %{conn: conn} do
    track_with("8A", 120.0, tag_title: "P1")
    track_with("8A", 120.5, tag_title: "P2")
    track_with("8A", 121.0, tag_title: "P3")

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "fill")

    view |> form("#section-fill") |> render_submit(%{role: "pico", count: "2"})

    [set] = Sets.list()
    entries = Sets.entries(set)
    assert length(entries) == 2
    assert Enum.count(entries, &(&1.role == "pico")) == 2
    # the section label is shown in the list
    assert render(view) =~ "Pico"
  end

  @tag :tmp_dir
  test "Planejar set builds a full arc-shaped, connected set", %{conn: conn} do
    for i <- 0..14, do: track_with("8A", 118.0 + i, tag_title: "T#{i}")

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "plan")

    view |> form("#plan-set-form") |> render_submit(%{count: "10"})

    [set] = Sets.list()
    entries = Sets.entries(set)
    assert length(entries) == 10
    assert hd(entries).role == "abertura"
    assert List.last(entries).role == "queda"
    assert Enum.all?(entries, &(&1.role in ~w(abertura pico respiro queda)))
    assert Enum.all?(tl(entries), &(&1.transition && &1.transition["enabled"]))
  end

  @tag :tmp_dir
  test "the set page renders the energy/BPM arc chart for a set with 2+ tracks", %{conn: conn} do
    {:ok, set} = Sets.create("Charted")
    t1 = track_with("8A", 120.0, tag_title: "A")
    t2 = track_with("9A", 124.0, tag_title: "B")
    {:ok, _} = Sets.append(set, t1, "pico")
    {:ok, _} = Sets.append(set, t2, "respiro")

    {:ok, _view, html} = live(conn, ~p"/set/#{set.id}")

    assert html =~ "Arco — energia + BPM"
    assert html =~ "<svg"
    assert html =~ "<polyline"
  end

  @tag :tmp_dir
  test "changing the section updates the candidate preview live", %{conn: conn} do
    track_with("8A", 121.0, tag_title: "Pool")
    {:ok, set} = Sets.create("S")
    Sets.append(set, track_with("8A", 120.0, tag_title: "Seed"))

    {:ok, view, _html} = live(conn, ~p"/set")
    open_panel(view, "fill")
    open_panel(view, "candidates")

    view |> form("#section-fill") |> render_change(%{role: "pico", count: "4"})
    assert render(view) =~ "Próxima faixa ideal · Pico"

    view |> form("#section-fill") |> render_change(%{role: "", count: "4"})
    assert render(view) =~ "Próxima faixa ideal · Automático"
  end

  @tag :tmp_dir
  test "search never offers a track already in the set", %{conn: conn} do
    member = track_with("8A", 120.0, tag_title: "ZZ One", norm_title: "zz one")
    other = track_with("8A", 121.0, tag_title: "ZZ Two", norm_title: "zz two")

    {:ok, set} = Sets.create("S")
    Sets.append(set, member)

    {:ok, view, _html} = live(conn, ~p"/set")
    open_panel(view, "search")
    view |> form("#track-search", %{q: "zz"}) |> render_change()

    refute has_element?(view, "#search-results button[phx-value-track='#{member.id}']")
    assert has_element?(view, "#search-results button[phx-value-track='#{other.id}']")
  end

  @tag :tmp_dir
  test "the Critérios modal reads the scoring config from the backend", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)

    html = view |> element("button[phx-click=show_criteria]") |> render_click()

    # the energy arc + a style-affinity cell, both sourced from the backend (the
    # per-criterion weights moved to the live "Mesa de mixagem" console)
    assert html =~ "Critérios"
    assert html =~ "arco de energia"
    assert html =~ "Pico"
    assert html =~ "Abertura"
    assert html =~ "Forró Roots"
    assert html =~ "Afinidade de estilos"
  end

  # --- mixing console (Task 4: state + events) ---

  @tag :tmp_dir
  test "adjusting a weight fader recomputes candidates (order changes)", %{conn: conn} do
    prev = track_with("8A", 120.0, tag_title: "Prev", norm_title: "prev")
    _bpm_match = track_with("11A", 121.0, tag_title: "BpmMatch")
    _key_match = track_with("8A", 150.0, tag_title: "KeyMatch")

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "search")
    view |> form("#track-search", %{q: "Prev"}) |> render_change()

    view
    |> element("#search-results button[phx-click=append][phx-value-track='#{prev.id}']")
    |> render_click()

    open_panel(view, "candidates")
    before = render(view)
    view |> render_hook("set_weight", %{"dim" => "bpm", "value" => "100"})
    after_html = render(view)
    refute before == after_html
  end

  @tag :tmp_dir
  test "reset_console restores default weights", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "console")

    view |> render_hook("set_weight", %{"dim" => "harmony", "value" => "0"})
    html = view |> element("button[phx-click=reset_console]") |> render_click()
    # harmony default fader restored to 30
    assert html =~ ~s(value="30")
  end

  @tag :tmp_dir
  test "toggling lock-key filters the candidate list", %{conn: conn} do
    prev = track_with("8A", 120.0, tag_title: "P2", norm_title: "p2")
    _compat = track_with("8A", 120.0, tag_title: "Compat2")
    _far = track_with("3B", 120.0, tag_title: "Far2")

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "search")
    view |> form("#track-search", %{q: "P2"}) |> render_change()

    view
    |> element("#search-results button[phx-click=append][phx-value-track='#{prev.id}']")
    |> render_click()

    open_panel(view, "console")
    open_panel(view, "candidates")
    view |> element("button[phx-click=toggle_harmonic]") |> render_click()
    html = render(view)
    assert html =~ "Compat2"
    refute html =~ "Far2"
  end

  @tag :tmp_dir
  test "the console renders faders (with the hook) and composition bars", %{conn: conn} do
    _t = track_with("8A", 120.0, tag_title: "X")
    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    # "Mesa de mixagem" header is always visible; the faders render once expanded.
    assert render(view) =~ "Mesa de mixagem"
    html = open_panel(view, "console")
    # the colocated ".Fader" hook normalizes to its module-qualified name at render
    assert html =~ ~s(phx-hook="BeatgridWeb.UI.Fader")
    assert html =~ ~s(data-dim="bpm")
  end

  @tag :tmp_dir
  test "the side panels collapse and expand (default collapsed)", %{conn: conn} do
    _t = track_with("8A", 120.0, tag_title: "X")
    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)

    # Collapsed by default: the header shows, the faders don't.
    html = render(view)
    assert html =~ "Mesa de mixagem"
    refute html =~ ~s(data-dim="bpm")

    # Expand: the faders render.
    assert open_panel(view, "console") =~ ~s(data-dim="bpm")

    # Collapse again: the faders are hidden, the header stays.
    collapsed = open_panel(view, "console")
    refute collapsed =~ ~s(data-dim="bpm")
    assert collapsed =~ "Mesa de mixagem"
  end

  @tag :tmp_dir
  test "the Sets list can be collapsed and reopened", %{conn: conn} do
    {:ok, set} = Sets.create("Hideable")
    {:ok, view, html} = live(conn, ~p"/set/#{set.id}")
    assert html =~ "Recolher lista de sets"

    collapsed = view |> element("button[phx-click=toggle_sets]") |> render_click()
    assert collapsed =~ "Mostrar lista de sets"
    refute collapsed =~ "Recolher lista de sets"

    reopened = view |> element("button[phx-click=toggle_sets]") |> render_click()
    assert reopened =~ "Recolher lista de sets"
  end

  @tag :tmp_dir
  test "play controls target the global player, not a local one", %{conn: conn} do
    seed =
      track_with("8A", 120.0,
        tag_title: "GlobalPlayerSeed",
        tag_artist: "A",
        norm_title: "globalplayerseed",
        norm_artist: "a"
      )

    {:ok, set} = Sets.create("Test set")
    Sets.append(set, seed)

    {:ok, _view, html} = live(conn, ~p"/set")
    assert html =~ ~s(id="player-audio")
    refute html =~ "set-player"
    assert html =~ "&quot;preview&quot;:false"
  end

  @tag :tmp_dir
  test "/set/:id deep-links a specific set (the player chip target)", %{conn: conn} do
    {:ok, older} = Sets.create("Primeiro")
    {:ok, _newer} = Sets.create("Segundo")

    # /set defaults to the most recent; /set/:id loads the requested one.
    {:ok, _view, html} = live(conn, ~p"/set/#{older.id}")
    assert html =~ ~s(value="Primeiro")
  end

  @tag :tmp_dir
  test "playing inside a set carries the set_id (set-mode auto-advance)", %{conn: conn} do
    seed =
      track_with("8A", 120.0,
        tag_title: "Seed",
        tag_artist: "A",
        norm_title: "seed",
        norm_artist: "a"
      )

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "search")
    view |> form("#track-search", %{q: "Seed"}) |> render_change()

    view
    |> element("#search-results button[phx-click=append][phx-value-track='#{seed.id}']")
    |> render_click()

    html = render(view)
    set = hd(Sets.list())
    assert html =~ "Tocar set"
    # the set id flows into the play dispatch (so playback enters set-mode)
    assert html =~ ~s(&quot;set_id&quot;:&quot;#{set.id}&quot;)
  end

  @tag :tmp_dir
  test "highlights the currently-playing track in the set", %{conn: conn} do
    seed =
      track_with("8A", 120.0,
        tag_title: "NowSeed",
        tag_artist: "A",
        norm_title: "nowseed",
        norm_artist: "a"
      )

    {:ok, set} = Sets.create("NowPlaying")
    Sets.append(set, seed)

    {:ok, view, _html} = live(conn, ~p"/set/#{set.id}")
    refute render(view) =~ "now-playing-disc"

    send(view.pid, {:now_playing, %{track_id: seed.id, set_id: set.id}})
    assert render(view) =~ "now-playing-disc"
  end

  @tag :tmp_dir
  test "/set/:id with an unknown id redirects to /set (drops the stale id)", %{conn: conn} do
    {:ok, _} = Sets.create("Existe")

    assert {:error, {:live_redirect, %{to: "/set"}}} =
             live(conn, ~p"/set/00000000-0000-0000-0000-000000000000")
  end

  @tag :tmp_dir
  test "flags a loudness jump between consecutive set tracks", %{conn: conn} do
    quiet =
      track_with("8A", 120.0,
        tag_title: "Quiet",
        tag_artist: "A",
        norm_title: "quiet",
        norm_artist: "a",
        loudness_lufs: -20.0
      )

    loud =
      track_with("8A", 121.0,
        tag_title: "Loud",
        tag_artist: "B",
        norm_title: "loud",
        norm_artist: "b",
        loudness_lufs: -10.0
      )

    {:ok, set} = Sets.create("Jumps")
    Sets.append(set, quiet)
    Sets.append(set, loud)

    {:ok, _view, html} = live(conn, ~p"/set/#{set.id}")
    assert html =~ "salto"
    assert html =~ "+10.0 LU"
  end

  @tag :tmp_dir
  test "selo Ouro aparece na tracklist do set", %{conn: conn} do
    {:ok, set} = Sets.create("Set Ouro")

    track =
      track_with("8A", 120.0,
        tag_title: "Pérola",
        tag_artist: "Luiz Gonzaga",
        norm_title: "perola",
        norm_artist: "luiz gonzaga",
        gold_status: :confirmed
      )

    Sets.append(set, track)

    {:ok, _view, html} = live(conn, ~p"/set/#{set.id}")
    assert html =~ "Ouro — não está no Soundcharts"
  end

  @tag :tmp_dir
  test "connects pairs with a suggested transition and renders the connector", %{conn: conn} do
    {:ok, set} = Sets.create("S")

    a =
      track_with("8A", 128.0,
        tag_title: "A",
        cue_points: [%{"ms" => 100_000, "type" => "outro", "source" => "auto"}]
      )

    b =
      track_with("8A", 129.0,
        tag_title: "B",
        cue_points: [%{"ms" => 4_000, "type" => "intro", "source" => "auto"}]
      )

    Sets.append(set, a)
    Sets.append(set, b)

    {:ok, view, html} = live(conn, ~p"/set/#{set.id}")
    assert html =~ "conectar"
    assert has_element?(view, "button[phx-click=connect_all]")

    view |> element("button[phx-click=connect_all]") |> render_click()

    entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
    assert entry_b.transition["type"] == "crossfade"
    assert entry_b.transition["from_ms"] == 100_000
    assert render(view) =~ "xfade"
  end
end
