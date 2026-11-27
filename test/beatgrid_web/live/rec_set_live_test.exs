defmodule BeatgridWeb.RecSetLiveTest do
  # async: false — exporting the set writes under the (overridden) library root.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Sets

  setup :isolate_library_root

  setup do
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
    song = build(:soundcharts_song, camelot: camelot, tempo_bpm: bpm, energy: 0.5)
    insert(:track, Keyword.merge([soundcharts_song: song, status: :present], attrs))
  end

  defp new_set(view),
    do: view |> element("button[phx-click=new_set]", "Novo set") |> render_click()

  # The right-rail panels start collapsed; open one before interacting with it.
  defp open_panel(view, id),
    do: view |> element("button[phx-value-panel='#{id}']") |> render_click()

  defp append_from_search(view, query, track) do
    open_panel(view, "search")
    view |> form("#track-search", %{q: query}) |> render_change()

    view
    |> element("#search-results button[phx-click=append][phx-value-track='#{track.id}']")
    |> render_click()
  end

  test "the editor displays the booth time for a protected ending with no outro cue", %{
    conn: conn
  } do
    a = track_with("8A", 112.0, sacred_ending: true, duration_ms: 200_000, cue_points: [])
    b = track_with("8A", 113.0, cue_points: [])
    {:ok, set} = Sets.create_filled("Fim de baile", [a, b])
    {:ok, _view, html} = live(conn, ~p"/set/#{set.id}")
    assert html =~ "sai 3:18"
    refute html =~ "sai ~fim"
  end

  test "a proposed recording waits for the chosen set, then appends at the end and opens the same set in the booth",
       %{conn: conn} do
    original = track_with("8A", 112.0, tag_title: "Asa Branca", rel_path: "Forró/original.mp3")
    proposed = track_with("8A", 114.0, tag_title: "Asa Branca", rel_path: "Forró/ao-vivo.mp3")
    {:ok, first} = Sets.create_filled("Primeiro baile", [original])
    {:ok, second} = Sets.create_filled("Segundo baile", [original])

    {:ok, view, html} = live(conn, ~p"/set?track_id=#{proposed.id}")
    assert has_element?(view, "#set-proposed-track", "Forró/ao-vivo.mp3")

    assert has_element?(
             view,
             "#set-proposed-track a[href='/track/#{proposed.id}']",
             "Voltar à ficha"
           )

    assert length(Regex.scan(~r/phx-click="new_set"/, html)) == 1
    assert has_element?(view, "aside button[phx-click=new_set]", "Novo set")
    assert has_element?(view, "#compact-set-id option[selected]", "Escolha um set")
    refute has_element?(view, "#set-add-proposed-track")
    refute has_element?(view, "#set-name")
    assert Enum.map(Sets.tracks(second), & &1.id) == [original.id]

    view |> element("aside a[href='/set/#{second.id}?track_id=#{proposed.id}']") |> render_click()
    assert_patch(view, ~p"/set/#{second.id}?track_id=#{proposed.id}")
    assert has_element?(view, "#set-proposed-track", "Segundo baile")

    assert has_element?(
             view,
             "#set-proposed-track a[href='/track/#{proposed.id}?set_id=#{second.id}']",
             "Voltar à ficha"
           )

    assert has_element?(
             view,
             "#set-add-proposed-track[phx-click=append][phx-value-track='#{proposed.id}']"
           )

    assert Enum.map(Sets.tracks(second), & &1.id) == [original.id]

    view |> element("#set-add-proposed-track") |> render_click()
    assert_patch(view, ~p"/set/#{second.id}")
    refute has_element?(view, "#set-proposed-track")
    assert Enum.map(Sets.tracks(second), & &1.id) == [original.id, proposed.id]
    assert Enum.map(Sets.tracks(first), & &1.id) == [original.id]
    assert has_element?(view, "a[href='/track/#{proposed.id}?set_id=#{second.id}']", "Asa Branca")

    view
    |> element("button[phx-click=move][phx-value-track='#{proposed.id}'][phx-value-dir=top]")
    |> render_click()

    assert Enum.map(Sets.tracks(second), & &1.id) == [proposed.id, original.id]
    assert has_element?(view, "a[href='/discotecagem?set=#{second.id}']", "Abrir na discotecagem")
  end

  test "new set remains reachable through the collapsed set picker", %{conn: conn} do
    track = track_with("8A", 112.0, tag_title: "Proposta")
    {:ok, view, _html} = live(conn, ~p"/set?track_id=#{track.id}")
    view |> element("button[aria-label='Recolher lista de sets']") |> render_click()
    refute has_element?(view, "button[phx-click=new_set]")
    view |> element("button[aria-label='Mostrar lista de sets']") |> render_click()
    assert has_element?(view, "aside button[phx-click=new_set]", "Novo set")
    assert has_element?(view, "#set-proposed-track", "Proposta")
  end

  test "creating a new set keeps the proposed recording until explicit insertion", %{conn: conn} do
    track = track_with("8A", 112.0, tag_title: "Proposta")
    {:ok, view, _html} = live(conn, ~p"/set?track_id=#{track.id}")
    assert has_element?(view, "#set-proposed-track", "Proposta")
    assert Sets.list() == []

    new_set(view)
    [created] = Sets.list()
    assert_patch(view, ~p"/set/#{created.id}?track_id=#{track.id}")
    assert Sets.tracks(created) == []
    assert has_element?(view, "#set-add-proposed-track")

    {:ok, reopened, _html} = live(conn, ~p"/set/#{created.id}?track_id=#{track.id}")
    reopened |> element("#set-add-proposed-track") |> render_click()
    assert_patch(reopened, ~p"/set/#{created.id}")
    assert Enum.map(Sets.tracks(created), & &1.id) == [track.id]
  end

  test "an existing member is identified and the proposed recording follows another selected set",
       %{conn: conn} do
    track = track_with("8A", 112.0, tag_title: "Já aqui")
    {:ok, member_set} = Sets.create_filled("Com ela", [track])
    {:ok, other_set} = Sets.create("Sem ela")

    {:ok, view, _html} = live(conn, ~p"/set/#{member_set.id}?track_id=#{track.id}")
    assert has_element?(view, "#set-proposed-track", "A faixa já está neste set")
    refute has_element?(view, "#set-add-proposed-track")
    assert length(Sets.tracks(member_set)) == 1

    view |> form("#compact-set-picker", set_id: other_set.id) |> render_change()
    assert_patch(view, ~p"/set/#{other_set.id}?track_id=#{track.id}")
    assert has_element?(view, "#set-add-proposed-track")
    assert Sets.tracks(other_set) == []
  end

  test "a deleted destination returns to the chooser with the exact proposed recording", %{
    conn: conn
  } do
    track = track_with("8A", 112.0, tag_title: "Proposta")
    {:ok, deleted} = Sets.create("Set removido")
    {:ok, remaining} = Sets.create("Outro baile")
    {:ok, view, _html} = live(conn, ~p"/set/#{deleted.id}?track_id=#{track.id}")

    {:ok, _} = Sets.delete(deleted)
    view |> element("#set-add-proposed-track") |> render_click()
    assert_patch(view, ~p"/set?track_id=#{track.id}")
    assert has_element?(view, "#set-proposed-track", "Proposta")
    refute has_element?(view, "#set-add-proposed-track")
    assert has_element?(view, "aside a[href='/set/#{remaining.id}?track_id=#{track.id}']")
    assert Sets.tracks(remaining) == []
  end

  test "invalid or unavailable proposed recordings never enter a set", %{conn: conn} do
    missing = track_with("8A", 112.0, integrity_status: :missing_file)
    {:ok, set} = Sets.create("Baile")

    for id <- ["invalid", Ecto.UUID.generate(), missing.id] do
      {:ok, view, _html} = live(conn, ~p"/set/#{set.id}?track_id=#{id}")
      refute has_element?(view, "#set-add-proposed-track")
      assert has_element?(view, "#flash-error", "Faixa indisponível")
    end

    assert Sets.tracks(set) == []
  end

  test "the proposed recording is revalidated when the user adds it", %{conn: conn} do
    track = track_with("8A", 112.0, tag_title: "Sumiu")
    {:ok, set} = Sets.create("Baile")
    {:ok, view, _html} = live(conn, ~p"/set/#{set.id}?track_id=#{track.id}")
    {:ok, _} = Tracks.update(track, %{integrity_status: :missing_file})

    view |> element("#set-add-proposed-track") |> render_click()
    assert_patch(view, ~p"/set/#{set.id}")
    assert has_element?(view, "#flash-error", "Faixa indisponível")
    assert Sets.tracks(set) == []
  end

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
    append_from_search(view, "Seed", seed)

    # search box stays visible and its detail link retains the set context.
    assert has_element?(view, "#track-search")
    [set] = Sets.list()
    assert has_element?(view, "#search-results a[href='/track/#{seed.id}?set_id=#{set.id}']")
    # play buttons target the global player, not a local one
    assert render(view) =~ ~s(id="player-audio")
    refute render(view) =~ ~s(id="set-player")

    # the harmonic candidate must show up in the candidates panel
    open_panel(view, "candidates")
    assert has_element?(view, "a[href='/track/#{nextt.id}?set_id=#{set.id}']", "Nexto")

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
  test "a set holding a track that left the library wears the ⚠ badge in the list", %{conn: conn} do
    {:ok, sick} = Sets.create("Festa do interior")
    gone = insert(:track, status: :quarantined, tag_title: "Sumida")
    {:ok, _} = Sets.append(sick, gone)

    {:ok, _view, html} = live(conn, ~p"/set")

    assert html =~ "⚠ 1"
    assert html =~ "fora da biblioteca"
  end

  test "choosing a target style anchors the set", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)

    view |> form("#target-style") |> render_change(%{style: "forro_roots"})

    [set] = Sets.list()
    assert set.target_style == "forro_roots"
  end

  test "an invalid rename keeps the editor open and a subsequent valid name saves", %{conn: conn} do
    {:ok, set} = Sets.create("Original")
    {:ok, view, _} = live(conn, ~p"/set/#{set.id}")

    for invalid <- ["", String.duplicate("a", 256)] do
      view |> form("#set-name", %{name: invalid}) |> render_change()
      assert Sets.get(set.id).name == "Original"
      assert has_element?(view, "#set-name [aria-invalid=true]")
    end

    view |> form("#set-name", %{name: "Baile de sexta"}) |> render_submit()
    assert Sets.get(set.id).name == "Baile de sexta"
    refute has_element?(view, "#set-name [aria-invalid=true]")
  end

  test "duplicating a set removed in another tab returns to the remaining set", %{conn: conn} do
    {:ok, other} = Sets.create("Outro baile")
    {:ok, set} = Sets.create("Removido")
    {:ok, view, _} = live(conn, ~p"/set/#{set.id}")
    {:ok, _} = Sets.delete(set)

    view |> element("button[phx-click=duplicate_set]") |> render_click()
    assert_patch(view, ~p"/set/#{other.id}")
    assert has_element?(view, "#set-name input[value='Outro baile']")
    assert render(view) =~ "Esse set já foi excluído."
    assert [remaining] = Sets.list()
    assert remaining.id == other.id
  end

  test "stale name, style and delete controls recover when another tab deletes the set", %{
    conn: conn
  } do
    {:ok, remaining} = Sets.create("Outro baile")

    for action <- [:rename, :style, :delete] do
      {:ok, gone} = Sets.create("Baile antigo")
      {:ok, view, _} = live(conn, ~p"/set/#{gone.id}")
      {:ok, _} = Sets.delete(gone)

      case action do
        :rename -> view |> form("#set-name", %{name: "Novo nome"}) |> render_submit()
        :style -> view |> form("#target-style") |> render_change(%{style: "forro_roots"})
        :delete -> view |> element("button[phx-click=delete_set]") |> render_click()
      end

      assert_patch(view, ~p"/set/#{remaining.id}")
      assert has_element?(view, "#set-name input[value='Outro baile']")
      assert render(view) =~ "Esse set já foi excluído."
    end
  end

  test "an async plan finishing after the editor was cleared cannot reload the deleted set" do
    {:ok, set} = Sets.create("Fim do baile")

    socket =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{},
        set: nil,
        planning_sets: MapSet.new([set.id])
      )

    assert {:noreply, finished} =
             BeatgridWeb.RecSetLive.handle_async(
               {:plan, set.id, "planejado"},
               {:ok, {:ok, set}},
               socket
             )

    assert is_nil(finished.assigns.set)
    assert Enum.empty?(finished.assigns.planning_sets)
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
    assert [%{role: "pico"}, %{role: "pico"}] = Sets.entries(set)
    # the section label is shown in the list
    assert render(view) =~ "Pico"
  end

  @tag :tmp_dir
  test "replacing a set with no matching candidates keeps its sequence and transitions", %{
    conn: conn
  } do
    first = track_with("8A", 120.0, tag_title: "Opening")
    last = track_with("9A", 122.0, tag_title: "Closing")
    {:ok, set} = Sets.create_filled("Baile", [first, last])
    {:ok, _} = Sets.connect(set, last, %{"type" => "echo"})
    before = Sets.entries(set)
    {:ok, view, _} = live(conn, ~p"/set/#{set.id}")

    open_panel(view, "plan")
    view |> form("#plan-set-form") |> render_submit(%{fill_mode: "replace", bpm_min: "220"})
    html = render_async(view)

    assert Sets.entries(set) == before
    assert html =~ "Nenhuma faixa atende aos critérios"
  end

  @tag :tmp_dir
  test "Planejar set builds a full arc-shaped, connected set", %{conn: conn} do
    for i <- 0..14, do: track_with("8A", 118.0 + i, tag_title: "T#{i}")

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "plan")

    view
    |> form("#plan-set-form")
    |> render_submit(%{mode: "tracks", track_count: "10", preset: "custom"})

    render_async(view)

    [set] = Sets.list()
    entries = Sets.entries(set)
    assert length(entries) == 10
    assert [%{role: "abertura"} | _] = entries
    assert %{role: "queda"} = List.last(entries)
    assert Enum.all?(entries, &(&1.role in ~w(abertura pico respiro queda)))
    assert Enum.all?(tl(entries), &(&1.transition && &1.transition["enabled"]))
  end

  @tag :tmp_dir
  test "the planner accepts long sets above the old 60-track cap", %{conn: conn} do
    for i <- 0..79 do
      track_with("8A", 118.0 + i / 10,
        genre_folder: "forro_roots",
        duration_ms: 180_000,
        tag_title: "Long #{i}"
      )
    end

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    html = open_panel(view, "plan")

    refute html =~ ~s(max="60")
    assert html =~ "Forro Roots Marathon"

    view
    |> form("#plan-set-form")
    |> render_submit(%{
      mode: "tracks",
      track_count: "70",
      duration_minutes: "300",
      preset: "forro_roots_marathon"
    })

    render_async(view, 10_000)

    [set] = Sets.list()
    assert length(Sets.entries(set)) == 70
  end

  @tag :tmp_dir
  test "the planner can estimate a five-hour set from track duration", %{conn: conn} do
    for i <- 0..104 do
      track_with("8A", 118.0 + i / 10,
        genre_folder: "forro_roots",
        duration_ms: 180_000,
        tag_title: "Five Hour #{i}"
      )
    end

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    open_panel(view, "plan")

    view
    |> form("#plan-set-form")
    |> render_submit(%{
      mode: "duration",
      track_count: "16",
      duration_minutes: "300",
      preset: "forro_roots_marathon"
    })

    # Planning 100 slots is the heaviest async in the suite — wait for it
    # explicitly instead of racing the assert against the task.
    render_async(view, 30_000)

    [set] = Sets.list()
    assert length(Sets.entries(set)) == 100
  end

  @tag :tmp_dir
  test "entries show the MANUAL BPM/key overrides, not the raw soundcharts values", %{conn: conn} do
    {:ok, set} = Sets.create("Corrigido")
    t = track_with("8A", 120.0, tag_title: "Ajustada", bpm_manual: 97.0, camelot_manual: "3B")
    {:ok, _} = Sets.append(set, t)

    {:ok, _view, html} = live(conn, ~p"/set/#{set.id}")

    assert html =~ ">97</span>"
    assert html =~ "3B"
    refute html =~ ">120</span>"
  end

  test "the set page renders the energy/BPM arc chart for a set with 2+ tracks", %{conn: conn} do
    {:ok, set} = Sets.create("Charted")
    t_1 = track_with("8A", 120.0, tag_title: "A")
    t_2 = track_with("9A", 124.0, tag_title: "B")
    {:ok, _} = Sets.append(set, t_1, "pico")
    {:ok, _} = Sets.append(set, t_2, "respiro")

    {:ok, _view, html} = live(conn, ~p"/set/#{set.id}")

    assert html =~ "Arco do set"
    assert html =~ "<svg"
    assert html =~ "<polyline"
  end

  @tag :tmp_dir
  test "Remixar reorganizes the current set's tracks into the arc", %{conn: conn} do
    {:ok, set} = Sets.create("Remixable")
    a = track_with("8A", 120.0, tag_title: "A")
    b = track_with("9A", 124.0, tag_title: "B")
    c = track_with("8A", 121.0, tag_title: "C")
    Enum.each([a, b, c], &Sets.append(set, &1))

    {:ok, view, _html} = live(conn, ~p"/set/#{set.id}")
    view |> element("button[phx-click=remix]") |> render_click()
    render_async(view)

    entries = Sets.entries(set)
    assert [_, _, _] = entries
    # every track got an arc role and the pairs are connected
    assert Enum.all?(entries, &(&1.role in ~w(abertura pico respiro queda)))
    assert Enum.all?(tl(entries), &(&1.transition && &1.transition["enabled"]))
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
  test "search flags tracks already in the set instead of hiding them", %{conn: conn} do
    member = track_with("8A", 120.0, tag_title: "ZZ One", norm_title: "zz one")
    other = track_with("8A", 121.0, tag_title: "ZZ Two", norm_title: "zz two")

    {:ok, set} = Sets.create("S")
    Sets.append(set, member)

    {:ok, view, _html} = live(conn, ~p"/set")
    open_panel(view, "search")
    view |> form("#track-search", %{q: "zz"}) |> render_change()

    # the in-set track shows up, but flagged and NOT addable…
    refute has_element?(
             view,
             "#search-results button[phx-click=append][phx-value-track='#{member.id}']"
           )

    assert render(view) =~ "✓ no set"
    # …while a non-member is still addable.
    assert has_element?(
             view,
             "#search-results button[phx-click=append][phx-value-track='#{other.id}']"
           )
  end

  @tag :tmp_dir
  test "the Critérios modal reads the scoring config from the backend", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)

    open_panel(view, "console")
    html = view |> element("#open-set-criteria") |> render_click()

    # the energy arc + a style-affinity cell, both sourced from the backend (the
    # per-criterion weights moved to the live "Mesa de mixagem" console)
    assert has_element?(view, "#set-criteria[role=dialog][aria-labelledby=set-criteria-title]")
    assert html =~ "Critérios"
    assert html =~ "arco de energia"
    assert html =~ "Pico"
    assert html =~ "Abertura"
    assert html =~ "Forró Roots"
    assert html =~ "Afinidade de estilos"
  end

  # --- mixing console (Task 4: state + events) ---

  test "the opening preview and section fill both honor the console BPM window", %{conn: conn} do
    allowed = track_with("8A", 112.0, tag_title: "Dentro da faixa")
    blocked = track_with("8A", 150.0, tag_title: "Fora da faixa")
    {:ok, set} = Sets.create("Filtrado")
    {:ok, view, _} = live(conn, ~p"/set/#{set.id}")
    open_panel(view, "console")
    open_panel(view, "candidates")
    view |> form("form[phx-change=set_filters]", %{bpm_max: "120"}) |> render_change()

    assert has_element?(view, "button[phx-click=append][phx-value-track='#{allowed.id}']")
    refute has_element?(view, "button[phx-click=append][phx-value-track='#{blocked.id}']")
    open_panel(view, "fill")
    view |> form("#section-fill") |> render_submit(%{role: "pico", count: "2"})
    assert [%{track: %{id: id}, role: "pico"}] = Sets.entries(set)
    assert id == allowed.id
  end

  @tag :tmp_dir
  test "adjusting a weight fader recomputes candidates (order changes)", %{conn: conn} do
    prev = track_with("8A", 120.0, tag_title: "Prev", norm_title: "prev")
    _bpm_match = track_with("11A", 121.0, tag_title: "BpmMatch")
    _key_match = track_with("8A", 150.0, tag_title: "KeyMatch")

    {:ok, view, _html} = live(conn, ~p"/set")
    new_set(view)
    append_from_search(view, "Prev", prev)

    open_panel(view, "candidates")
    before = render(view)
    view |> render_hook("set_weight", %{"dim" => "bpm", "value" => "100"})
    after_html = render(view)
    refute before == after_html
  end

  @tag :tmp_dir
  test "the track order opens the existing catalog search even when the set is empty", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/set")
    new_set(view)
    refute has_element?(view, "#track-search")
    view |> element("#set-find-track") |> render_click()
    assert has_element?(view, "#track-search-input")
    assert has_element?(view, "#set-find-track[phx-click*='focus']")
    assert has_element?(view, "button[phx-value-panel=search][aria-expanded=true]")
  end

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
    append_from_search(view, "P2", prev)

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

  test "selecting, duplicating and creating a set put the edited set in the address", %{
    conn: conn
  } do
    {:ok, first} = Sets.create("Primeiro")
    {:ok, second} = Sets.create("Segundo")
    {:ok, view, _} = live(conn, ~p"/set/#{first.id}")
    view |> element("aside a[href='/set/#{second.id}']") |> render_click()
    assert_patch(view, ~p"/set/#{second.id}")

    view |> element("button[phx-click=duplicate_set]") |> render_click()
    copy = Enum.find(Sets.list(), &(&1.name == "Segundo (cópia)"))
    assert_patch(view, ~p"/set/#{copy.id}")

    view |> element("button[phx-click=new_set]") |> render_click()
    created = Enum.find(Sets.list(), &(&1.name == "Novo set"))
    assert_patch(view, ~p"/set/#{created.id}")
    {:ok, reopened, _} = live(conn, ~p"/set/#{created.id}")
    assert has_element?(reopened, "#set-name input[value='Novo set']")
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
    append_from_search(view, "Seed", seed)

    html = render(view)
    [set] = Sets.list()
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
  test "track names in the set link to the track page", %{conn: conn} do
    seed =
      track_with("8A", 120.0,
        tag_title: "LinkedSeed",
        tag_artist: "A",
        norm_title: "linkedseed",
        norm_artist: "a"
      )

    {:ok, set} = Sets.create("Linked Set")
    Sets.append(set, seed)

    {:ok, view, _html} = live(conn, ~p"/set/#{set.id}")

    assert has_element?(view, "a[href='/track/#{seed.id}?set_id=#{set.id}']", "LinkedSeed")
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
    refute Map.has_key?(entry_b.transition, "from_ms")

    # the pair row shows the DERIVED mix points (a's outro, b's intro)
    html = render(view)
    assert html =~ "xfade"
    assert html =~ "sai 1:40"
    assert html =~ "entra 0:04"
  end

  test "the 🤝 toggle turns a boundary into a breather and back", %{conn: conn} do
    {:ok, set} = Sets.create("S")
    a = track_with("8A", 128.0, tag_title: "A", cue_points: [])
    b = track_with("8A", 129.0, tag_title: "B", cue_points: [])
    Sets.append(set, a)
    Sets.append(set, b)
    {:ok, _} = Sets.connect(set, b, %{"type" => "echo"})

    {:ok, view, html} = live(conn, ~p"/set/#{set.id}")
    assert html =~ "toggle_breather"

    view |> element("button[phx-click=toggle_breather]") |> render_click()
    entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
    assert entry_b.transition["breather"] == true

    view |> element("button[phx-click=toggle_breather]") |> render_click()
    entry_b = Enum.find(Sets.entries(set), &(&1.track.id == b.id))
    refute Map.has_key?(entry_b.transition, "breather")
  end

  test "scratch transitions have distinct controls and changing type keeps the breather override",
       %{conn: conn} do
    a = track_with("8A", 120.0, tag_title: "A")
    b = track_with("8A", 121.0, tag_title: "B")
    {:ok, set} = Sets.create_filled("Salão", [a, b])
    {:ok, _} = Sets.set_breather(set, b, true)
    {:ok, view, _} = live(conn, ~p"/set/#{set.id}")

    for {type, label} <- [
          {"scratch_cut", "rasgo"},
          {"spinback", "rebobina"},
          {"chirp", "chirp"},
          {"transform", "transf"},
          {"scribble", "risca"}
        ] do
      assert has_element?(view, "button[phx-value-type='#{type}']", label)
    end

    view |> element("button[phx-value-type=chirp]") |> render_click()
    assert [%{}, %{transition: %{"type" => "chirp", "breather" => true}}] = Sets.entries(set)
    assert has_element?(view, "button[phx-value-type=chirp][aria-pressed=true]")
  end

  test "a breather click from an outdated list recovers if the receiving track was removed", %{
    conn: conn
  } do
    a = track_with("8A", 120.0, tag_title: "A")
    b = track_with("8A", 121.0, tag_title: "B")
    {:ok, set} = Sets.create_filled("Salão", [a, b])
    {:ok, view, _} = live(conn, ~p"/set/#{set.id}")
    :ok = Sets.remove(set, b)

    html =
      view |> element("[phx-click=toggle_breather][phx-value-track='#{b.id}']") |> render_click()

    assert html =~ "Faixa não encontrada"
    refute has_element?(view, "[phx-click=toggle_breather][phx-value-track='#{b.id}']")
  end

  test "a pair the DJ taught shows the learned exit with the 📌 badge", %{conn: conn} do
    {:ok, set} = Sets.create("S")

    a =
      track_with("8A", 128.0,
        tag_title: "A",
        duration_ms: 200_000,
        cue_points: [%{"ms" => 180_000, "type" => "outro", "source" => "auto"}]
      )

    b = track_with("8A", 129.0, tag_title: "B", cue_points: [])
    Sets.append(set, a)
    Sets.append(set, b)
    {:ok, _} = Sets.connect(set, b, %{"type" => "crossfade"})
    {:ok, _} = Sets.learn_fire_point(set.id, b.id, a.id, 120_000)

    {:ok, _view, html} = live(conn, ~p"/set/#{set.id}")
    assert html =~ "sai 2:00 📌"
  end

  test "adding a search result after another tab deletes the set keeps the editor usable", %{
    conn: conn
  } do
    {:ok, surviving} = Sets.create("Próximo baile")
    {:ok, deleted} = Sets.create("Rascunho")
    track = track_with("8A", 112.0, tag_title: "Sanfona", norm_title: "sanfona")
    {:ok, view, _} = live(conn, ~p"/set/#{deleted.id}")
    open_panel(view, "search")
    view |> form("#track-search", %{q: "Sanfona"}) |> render_change()

    {:ok, _} = Sets.delete(deleted)
    view |> element("#search-results [phx-value-track='#{track.id}']") |> render_click()

    assert_patch(view, ~p"/set/#{surviving.id}")
    assert render(view) =~ "Esse set já foi excluído"
    assert Sets.tracks(surviving) == []
  end

  test "hostile move/weight payloads are ignored, never crash the view", %{conn: conn} do
    {:ok, set} = Sets.create("Blindado")
    track = track_with("8A", 120.0, tag_title: "Firme")
    {:ok, _} = Sets.append(set, track)

    {:ok, view, _html} = live(conn, ~p"/set/#{set.id}")

    render_click(view, "move", %{"track" => track.id, "dir" => "not_an_existing_atom_xyz"})
    render_click(view, "set_weight", %{"dim" => "delete", "value" => "50"})

    assert render(view) =~ "Firme"
  end
end
