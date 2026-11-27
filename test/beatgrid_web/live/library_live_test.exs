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

    insert(:track,
      status: :present,
      tag_title: "Perdida no Set",
      source_playlist: "recorte",
      rel_path: "_Inbox/recorte.mp3"
    )

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Biblioteca"
    assert html =~ "Sina"
    assert html =~ "Asa Branca"

    # recortes carry their ✂ badge in the row
    assert html =~ "Recorte — gravada por você"

    filtered = view |> element("button[phx-value-key='mpb']") |> render_click()
    assert filtered =~ "Sina"
    refute filtered =~ "Asa Branca"
  end

  test "the compact menu controls the same destinations as the desktop rail", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "button[aria-expanded=false][aria-controls=app-destinations]",
             "Menu"
           )

    assert has_element?(view, "nav img[src='/images/logo.svg'][alt='']")

    for path <- ["/", "/set", "/discotecagem", "/painel", "/ajustes"] do
      assert has_element?(view, "#app-destinations a[href='#{path}']")
    end

    assert has_element?(view, "#app-destinations a[aria-current=page]", "Biblioteca")
  end

  test "renders the grouped, collapsible navigation rail", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    # Workflow grouping (Coleção → Curadoria → Sistema)
    assert html =~ "Coleção"
    assert html =~ "Curadoria"
    assert html =~ "Sistema"

    # Every route stays reachable from the rail
    for href <- ~w(/ /set /painel /importados /revisao /dedup /generos /jobs) do
      assert html =~ ~s(href="#{href}")
    end

    # Collapse toggle + accessibility hooks
    assert html =~ "data-nav-toggle"
    assert html =~ ~s(aria-label="Navegação principal")
    assert html =~ ~s(aria-label="Recolher menu lateral")
    assert html =~ ~s(aria-label="Expandir menu lateral")
    # Active route marks itself for assistive tech, nothing renders aria-current="false"
    assert html =~ ~s(aria-current="page")
    refute html =~ ~s(aria-current="false")
  end

  test "library rows can play in the global player and still link to the track", %{conn: conn} do
    track = insert(:track, status: :present, tag_title: "Sina", tag_artist: "Djavan")

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "beatgrid:play"
    assert html =~ "#player-audio"
    assert has_element?(view, "a[href='/track/#{track.id}']", "Sina")
    refute html =~ ~s(<a href="/track/#{track.id}" class="contents">)
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

  test "empty collection offers import and row actions expose the track name", %{conn: conn} do
    {:ok, empty_view, _} = live(conn, ~p"/")
    assert has_element?(empty_view, "#library-rows a[href='/importados?origem=local']")

    insert(:track, tag_title: "Sina", status: :present)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "button[aria-label='Ações de Sina']")
    view |> element("button[phx-click=toggle_select_mode]") |> render_click()
    assert has_element?(view, "button[aria-label='Selecionar Sina']")
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
      asc = view |> element("#library-rows button[phx-value-by='bpm']") |> render_click()
      assert before?(asc, "Slow", "Fast")

      # clicking BPM again toggles to descending → fast (150) before slow (90)
      desc = view |> element("#library-rows button[phx-value-by='bpm']") |> render_click()
      assert before?(desc, "Fast", "Slow")
    end
  end

  test "search and rating keep each other's criteria when either form changes", %{conn: conn} do
    for {title, artist, rating} <- [
          {"Sina", "Djavan", 8},
          {"Oceano", "Djavan", 3},
          {"Romaria", "Elis", 9}
        ] do
      insert(:track,
        status: :present,
        tag_title: title,
        tag_artist: artist,
        norm_artist: String.downcase(artist),
        norm_title: String.downcase(title),
        rating: rating
      )
    end

    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("#library-search", %{search: "Djavan"}) |> render_change()
    view |> form("#library-filters", %{rating_min: "7"}) |> render_change()

    assert has_element?(view, "#library-rows", "Sina")
    refute has_element?(view, "#library-rows", "Oceano")
    refute has_element?(view, "#library-rows", "Romaria")
    assert has_element?(view, "#library-search input[value=Djavan]")

    view |> form("#library-search", %{search: ""}) |> render_submit()
    assert has_element?(view, "#library-rows", "Romaria")
    refute has_element?(view, "#library-rows", "Oceano")

    view |> form("#library-filters", %{rating_min: ""}) |> render_change()
    assert has_element?(view, "#library-rows", "Oceano")
  end

  test "closed filters expose criteria and removing one preserves search and the others", %{
    conn: conn
  } do
    for {title, artist, folder, rating} <- [
          {"Sina", "Djavan", "mpb", 8},
          {"Oceano", "Djavan", "mpb", 3},
          {"Flor", "Djavan", "forro_roots", 8},
          {"Romaria", "Elis", "mpb", 9}
        ] do
      insert(:track,
        tag_title: title,
        tag_artist: artist,
        norm_artist: String.downcase(artist),
        norm_title: String.downcase(title),
        genre_folder: folder,
        rating: rating
      )
    end

    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("#library-search", %{search: "Djavan"}) |> render_change()
    refute has_element?(view, "#library-active-filters")
    view |> element("#library-filter-toggle") |> render_click()
    view |> element("#library-filter-panel button[phx-value-key=mpb]") |> render_click()
    view |> form("#library-filters", %{rating_min: "7", rating_max: "9"}) |> render_change()
    view |> element("#library-filter-toggle") |> render_click()

    assert has_element?(view, "#library-filter-toggle[aria-expanded=false]")
    assert has_element?(view, "#library-remove-genre_folder", "MPB")
    assert has_element?(view, "#library-remove-rating", "Nota 7–9")
    assert has_element?(view, "#library-rows", "Sina")
    refute has_element?(view, "#library-rows", "Oceano")
    refute has_element?(view, "#library-rows", "Flor")

    view |> element("#library-remove-rating") |> render_click()
    refute has_element?(view, "#library-remove-rating")
    assert has_element?(view, "#library-rows", "Oceano")
    refute has_element?(view, "#library-rows", "Flor")
    assert has_element?(view, "#library-remove-genre_folder", "MPB")

    view |> element("#library-remove-genre_folder") |> render_click()
    refute has_element?(view, "#library-active-filters")
    assert has_element?(view, "#library-rows", "Flor")
    refute has_element?(view, "#library-rows", "Romaria")
    render_click(view, "remove_filter", %{"filter" => "search"})
    assert has_element?(view, "#library-search input[value=Djavan]")
    refute has_element?(view, "#library-rows", "Romaria")
  end

  test "range and Camelot summaries remove their paired constraints independently", %{conn: conn} do
    for {title, key, bpm} <- [
          {"Referência", "8A", 110},
          {"Vizinha", "8B", 118},
          {"Distante", "3B", 118},
          {"Rápida", "8A", 140}
        ] do
      insert(:track,
        tag_title: title,
        rating: 8,
        soundcharts_song: build(:soundcharts_song, camelot: key, tempo_bpm: bpm, energy: 0.6)
      )
    end

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#library-filter-toggle") |> render_click()

    view
    |> form("#library-filters", %{
      rating_min: "0",
      energy_max: "72",
      bpm_min: "105",
      bpm_max: "125"
    })
    |> render_change()

    view |> element("#library-wheel-toggle") |> render_click()
    view |> element("input[phx-click=toggle_camelot_compatible]") |> render_click()
    refute has_element?(view, "#library-remove-camelot")
    view |> form("#library-wheel-choice", %{code: "8A"}) |> render_change()
    render_keydown(view, "close_tom_wheel", %{"key" => "Escape"})
    view |> element("#library-filter-toggle") |> render_click()

    assert has_element?(view, "#library-remove-rating", "Nota ≥ 0")
    assert has_element?(view, "#library-remove-energy", "Energia ≤ 72")
    assert has_element?(view, "#library-remove-bpm", "BPM 105–125")
    assert has_element?(view, "#library-remove-camelot", "Tom 8A + compatíveis")
    assert has_element?(view, "#library-rows", "Vizinha")
    refute has_element?(view, "#library-rows", "Distante")
    refute has_element?(view, "#library-rows", "Rápida")

    view |> element("#library-remove-bpm") |> render_click()
    refute has_element?(view, "#library-remove-bpm")
    assert has_element?(view, "#library-rows", "Rápida")
    refute has_element?(view, "#library-rows", "Distante")

    view |> element("#library-remove-camelot") |> render_click()
    refute has_element?(view, "#library-remove-camelot")
    assert has_element?(view, "#library-rows", "Distante")
    assert has_element?(view, "#library-remove-energy", "Energia ≤ 72")
    assert has_element?(view, "#library-remove-rating", "Nota ≥ 0")
    view |> element("#library-filter-toggle") |> render_click()
    view |> element("#library-wheel-toggle") |> render_click()

    refute has_element?(
             view,
             "#library-wheel input[phx-click=toggle_camelot_compatible][checked]"
           )
  end

  test "tag, confidence, gold and unclassified chips reflect and release their criteria", %{
    conn: conn
  } do
    tag = "Pico da pista — repertório de sábado"

    for {title, attrs} <- [
          {"Referência", []},
          {"Sem tag", [tags: []]},
          {"Sem confiança", [sc_match_confidence: :low]},
          {"Sem ouro", [gold_status: nil]},
          {"Classificada", [genre_folder: "mpb"]}
        ] do
      insert(
        :track,
        Keyword.merge(
          [
            tag_title: title,
            tags: [tag],
            sc_match_confidence: :high,
            gold_status: :confirmed
          ],
          attrs
        )
      )
    end

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-value-tag]", tag) |> render_click()
    view |> element("button[phx-value-level=high]") |> render_click()
    view |> element("button[phx-click=toggle_gold_filter]") |> render_click()
    view |> element("button[phx-click=toggle_unclassified]") |> render_click()

    for {group, label, title} <- [
          {"tag", "Tag: #{tag}", "Sem tag"},
          {"confidence", "Confiança alta", "Sem confiança"},
          {"gold", "Ouro", "Sem ouro"},
          {"unclassified", "Não classificadas", "Classificada"}
        ] do
      assert has_element?(view, "#library-rows", "Referência")
      assert has_element?(view, "#library-remove-#{group}", label)
      refute has_element?(view, "#library-rows", title)
      view |> element("#library-remove-#{group}") |> render_click()
      assert has_element?(view, "#library-rows", title)
      refute has_element?(view, "#library-remove-#{group}")
    end

    refute has_element?(view, "#library-active-filters")
  end

  describe "extended filter rail" do
    test "the key dialog lets a keyboard user choose and clear every Camelot key", %{conn: conn} do
      for {title, key} <- [{"Sina", "8A"}, {"Romaria", "9A"}] do
        insert(:track,
          tag_title: title,
          status: :present,
          soundcharts_song: build(:soundcharts_song, camelot: key)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#library-wheel-toggle") |> render_click()
      assert has_element?(view, "#library-wheel[role=dialog][aria-modal=true][phx-key=Escape]")

      for n <- 1..12, mode <- ~w(A B) do
        assert has_element?(view, ~s|#library-wheel-code option[value="#{n}#{mode}"]|)
      end

      choice = form(view, "#library-wheel-choice", %{code: "8A"})
      render_change(choice)
      render_change(choice)
      assert has_element?(view, "#library-rows", "Sina")
      refute has_element?(view, "#library-rows", "Romaria")

      view |> form("#library-wheel-choice", %{code: ""}) |> render_change()
      assert has_element?(view, "#library-rows", "Romaria")
      render_keydown(view, "close_tom_wheel", %{"key" => "Escape"})
      refute has_element?(view, "#library-wheel")
      assert has_element?(view, "#library-wheel-toggle[aria-expanded=false]")
    end

    test "the Tom wheel filters by the clicked key and widens to compatibles", %{conn: conn} do
      insert(:track,
        status: :present,
        tag_title: "Keep",
        tag_artist: "Keeper",
        norm_artist: "keeper",
        soundcharts_song: build(:soundcharts_song, camelot: "8A")
      )

      insert(:track,
        status: :present,
        tag_title: "Neighbor",
        tag_artist: "Near",
        norm_artist: "near",
        soundcharts_song: build(:soundcharts_song, camelot: "8B")
      )

      insert(:track,
        status: :present,
        tag_title: "Drop",
        tag_artist: "Dropper",
        norm_artist: "dropper",
        soundcharts_song: build(:soundcharts_song, camelot: "3B")
      )

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("button[phx-click=toggle_tom_wheel]") |> render_click()

      # Click the 8A wedge: only 8A matches; 8B (a neighbor) and 3B are out.
      html = view |> element(~s|path[phx-value-code="8A"]|) |> render_click()
      assert html =~ "Keep"
      refute html =~ "Neighbor"
      refute html =~ "Drop"

      # Toggle "incluir compatíveis": 8B (neighbor of 8A) joins; 3B stays out.
      html_2 = view |> element("input[phx-click=toggle_camelot_compatible]") |> render_click()
      assert html_2 =~ "Keep"
      assert html_2 =~ "Neighbor"
      refute html_2 =~ "Drop"
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

    test "clicking a tag chip narrows to tracks carrying that tag", %{conn: conn} do
      insert(:track,
        status: :present,
        tag_title: "Tagged",
        tag_artist: "Withtag",
        norm_artist: "withtag",
        tags: ["abertura"]
      )

      insert(:track,
        status: :present,
        tag_title: "Plain",
        tag_artist: "Notag",
        norm_artist: "notag",
        tags: []
      )

      {:ok, view, html} = live(conn, ~p"/")
      # The chip is rendered because the tag exists in the library.
      assert html =~ "abertura"

      filtered = view |> element("button[phx-value-tag='abertura']") |> render_click()
      assert filtered =~ "Tagged"
      refute filtered =~ "Plain"
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

  test "compact filters reopen with the chosen folder and keep its result in the list", %{
    conn: conn
  } do
    insert(:track, tag_title: "No forró", genre_folder: "forro_roots")
    insert(:track, tag_title: "Na MPB", genre_folder: "mpb")
    {:ok, view, _html} = live(conn, ~p"/")
    toggle = "#library-filter-toggle"

    assert has_element?(
             view,
             "#{toggle}[aria-controls=library-filter-panel][aria-expanded=false]"
           )

    view |> element(toggle) |> render_click()
    assert has_element?(view, "#{toggle}[aria-expanded=true]")
    view |> element("#library-filter-panel button[phx-value-key=mpb]") |> render_click()
    view |> element(toggle) |> render_click()
    assert has_element?(view, "#{toggle}[aria-expanded=false]")
    assert has_element?(view, "#library-rows", "Na MPB")
    refute has_element?(view, "#library-rows", "No forró")

    view |> element(toggle) |> render_click()

    assert has_element?(
             view,
             "#library-filter-panel button[phx-value-key=mpb][aria-pressed=true]"
           )
  end

  test "the table shows the manual BPM/key override, not the Soundcharts value", %{conn: conn} do
    insert(:track,
      status: :present,
      tag_artist: "Override",
      tag_title: "Manual",
      norm_artist: "override",
      soundcharts_song: build(:soundcharts_song, tempo_bpm: 120.0, camelot: "8A"),
      bpm_manual: 132.0,
      camelot_manual: "11A"
    )

    {:ok, _view, html} = live(conn, ~p"/")
    # Each cell renders a single value, so showing 132/11A proves the manual
    # override clause matched ahead of the Soundcharts 120/8A.
    assert html =~ "132"
    assert html =~ "11A"
  end

  test "shows the suggested gain in the Vol. column for a measured track", %{conn: conn} do
    insert(:track,
      status: :present,
      tag_artist: "A",
      tag_title: "Loud",
      loudness_lufs: -20.0,
      true_peak_dbtp: -8.0
    )

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Vol."
    assert html =~ "+6.0 dB"
  end

  test "filtro Ouro mostra só faixas Ouro", %{conn: conn} do
    insert(:track,
      status: :present,
      gold_status: :confirmed,
      tag_title: "Joia Rara",
      norm_title: "joia rara"
    )

    insert(:track, status: :present, tag_title: "Comum", norm_title: "comum")

    {:ok, view, _} = live(conn, ~p"/")
    html = view |> element("button[phx-click=toggle_gold_filter]") |> render_click()

    assert html =~ "Joia Rara"
    refute html =~ "Comum"
  end

  test "paginates at 100, appends on load_more, and Marcar todas spans all pages", %{conn: conn} do
    for i <- 1..101 do
      n = String.pad_leading(Integer.to_string(i), 3, "0")

      insert(:track,
        status: :present,
        tag_artist: "A#{n}",
        tag_title: "T#{n}",
        norm_artist: "a#{n}",
        norm_title: "t#{n}"
      )
    end

    {:ok, view, html} = live(conn, ~p"/")
    # Header counts ALL matching, not just the loaded page.
    assert html =~ "101 faixas"
    # Page 1 = first 100 by artist; the 101st only arrives on scroll.
    assert html =~ "A001"
    refute html =~ "A101"
    assert html =~ "Carregar mais faixas"

    html_2 = render_hook(view, "load_more", %{})
    assert html_2 =~ "A101"
    refute html_2 =~ "Carregar mais faixas"

    # "Marcar todas" selects every matching id (across pages), not just loaded rows.
    view |> element("button[phx-click=toggle_select_mode]") |> render_click()
    html_3 = view |> element("button[phx-click=select_all]") |> render_click()
    assert html_3 =~ "101 selecionadas"
  end

  test "a hostile sort column is ignored, never crashes the view", %{conn: conn} do
    insert(:track, status: :present, tag_title: "Sobrevive")

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "sort", %{"by" => "not_an_existing_atom_xyz"})
    render_click(view, "sort", %{"by" => "delete"})

    assert render(view) =~ "Sobrevive"
  end

  # True if `a` appears before `b` in the rendered HTML.
  defp before?(html, a, b) do
    ia = :binary.match(html, a) |> elem(0)
    ib = :binary.match(html, b) |> elem(0)
    ia < ib
  end
end
