defmodule BeatgridWeb.MixesLiveTest do
  use BeatgridWeb.ConnCase, async: true, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  test "lists mixes and renders the import box", %{conn: conn} do
    insert(:mix, title: "Awakenings 2024", dj: "DJ X", status: :ready)

    {:ok, _view, html} = live(conn, ~p"/sets-online")

    assert html =~ "Sets gravados"
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
    assert html =~ "Faixas"
    assert html =~ "Na biblioteca"
    assert html =~ "50%"
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
    assert html =~ "YouTube"
    assert html =~ "Gravação adicionada à fila"
  end

  test "import confirmation links to the new recording even with a search active", %{conn: conn} do
    previous = insert(:mix, title: "Baile anterior", status: :ready)
    {:ok, view, _html} = live(conn, ~p"/sets-online")
    view |> form("#mix-search", query: "Baile anterior") |> render_change()

    url = "https://soundcloud.com/dj/nova-gravacao"
    view |> form("#mix-import-form", url: url) |> render_submit()

    mix = Enum.find(Beatgrid.Mixes.list_mixes(), &(&1.source_url == url))
    assert_enqueued(worker: Beatgrid.Workers.MixDownloadWorker)
    assert has_element?(view, "#mix-query[value='Baile anterior']")
    assert has_element?(view, "#recorded-mix-#{previous.id}")
    refute has_element?(view, "#recorded-mix-#{mix.id}")
    assert has_element?(view, "#mix-import-feedback [role=status]", "Gravação adicionada à fila")

    assert has_element?(
             view,
             "#mix-import-open[href='/sets-online/#{mix.id}']",
             "Abrir ficha"
           )

    result = view |> element("#mix-import-open") |> render_click()
    assert {:ok, _detail, _html} = follow_redirect(result, conn, ~p"/sets-online/#{mix.id}")
  end

  test "existing recording link opens the right detail rather than reimporting", %{conn: conn} do
    url = "https://soundcloud.com/dj/gravacao-existente"
    mix = insert(:mix, title: "Set existente", source_url: url, status: :ready)
    {:ok, view, _html} = live(conn, ~p"/sets-online")
    view |> form("#mix-search", query: "Outro DJ") |> render_change()

    view |> form("#mix-import-form", url: url) |> render_submit()
    refute has_element?(view, "#recorded-mix-#{mix.id}")
    assert has_element?(view, "#mix-query[value='Outro DJ']")
    refute_enqueued(worker: Beatgrid.Workers.MixDownloadWorker)
    assert has_element?(view, "#mix-import-open[href='/sets-online/#{mix.id}']")
    assert has_element?(view, "#mix-import-feedback [role=status]", "Já existe uma gravação")
    assert has_element?(view, "#mix-source-url[value='#{url}']")

    view |> form("#mix-import-form", url: "https://vimeo.com/1") |> render_submit()
    refute has_element?(view, "#mix-import-open")
    assert has_element?(view, "#mix-import-feedback [role=status]", "YouTube ou SoundCloud")
  end

  test "recording title and visible detail action share a single internal link", %{conn: conn} do
    title = String.duplicate("Festival de Forró — ", 9) <> "DJ Raízes"
    url = "https://soundcloud.com/dj/" <> String.duplicate("a", 150)
    mix = insert(:mix, title: title, source_url: url, status: :failed, error: "Falha no download")

    pending =
      insert(:mix,
        title: nil,
        source_url: url <> "-pending",
        status: :downloading
      )

    {:ok, view, _html} = live(conn, ~p"/sets-online")
    row = "#recorded-mix-#{mix.id}"
    detail = "#{row} a[href='/sets-online/#{mix.id}']"

    assert has_element?(view, detail, title)
    assert has_element?(view, detail, "Abrir ficha")
    assert has_element?(view, "#{row} a[href='#{url}'][target=_blank]", "SoundCloud")
    assert has_element?(view, row, "Falha no download")

    assert has_element?(
             view,
             "#recorded-mix-#{pending.id} a[href='/sets-online/#{pending.id}']",
             pending.source_url
           )

    result = view |> element(detail) |> render_click()
    assert {:ok, _detail, _html} = follow_redirect(result, conn, ~p"/sets-online/#{mix.id}")
  end

  test "rejects an unsupported url with a friendly message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sets-online")
    render_submit(element(view, "#mix-import-form"), %{"url" => "https://vimeo.com/1"})
    assert render(view) =~ "YouTube ou SoundCloud"
    assert has_element?(view, "input[name=url][value='https://vimeo.com/1']")
  end

  test "searches recordings by title or DJ and can clear the search", %{conn: conn} do
    insert(:mix, title: "Baile de domingo", dj: "DJ Raízes", status: :ready)
    insert(:mix, title: "Outra gravação", dj: "DJ X", status: :ready)

    {:ok, view, _} = live(conn, ~p"/sets-online")
    view |> form("#mix-search", query: "raízes") |> render_submit()
    assert has_element?(view, "#recorded-mixes article", "Baile de domingo")
    refute has_element?(view, "#recorded-mixes article", "Outra gravação")
    view |> element("button[phx-click=clear_search]") |> render_click()
    assert has_element?(view, "#recorded-mixes article", "Outra gravação")
  end
end
