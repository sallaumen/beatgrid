defmodule BeatgridWeb.ImportsLiveTest do
  use BeatgridWeb.ConnCase, async: false, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Sets

  import Mox
  setup :set_mox_global
  setup :verify_on_exit!
  setup :isolate_library_root

  defp playlist_track(title, playlist_url, index, playlist_title) do
    insert(:track,
      status: :present,
      source_playlist: "youtube",
      tag_title: title,
      norm_title: String.downcase(title),
      raw_tags: %{
        "youtube_playlist_url" => playlist_url,
        "youtube_playlist_index" => index,
        "youtube_playlist_title" => playlist_title
      }
    )
  end

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
    end

    :ok
  end

  test "lista só faixas do youtube", %{conn: conn} do
    youtube_track =
      insert(:track,
        status: :present,
        source_playlist: "youtube",
        tag_title: "Do Tubo",
        norm_title: "do tubo"
      )

    insert(:track,
      status: :present,
      source_playlist: "import",
      tag_title: "Do Disco",
      norm_title: "do disco"
    )

    {:ok, view, html} = live(conn, ~p"/importados")
    assert html =~ "Do Tubo"
    assert has_element?(view, "a[href='/track/#{youtube_track.id}']", "Do Tubo")
    refute html =~ "Do Disco"
  end

  test "toggle Ouro marca manual", %{conn: conn} do
    t = insert(:track, status: :present, source_playlist: "youtube", tag_title: "Marcar")

    {:ok, view, _} = live(conn, ~p"/importados")
    view |> element("button[phx-click=toggle_gold][phx-value-id='#{t.id}']") |> render_click()

    assert Tracks.get(t.id).gold_manual == true

    view |> element("button[phx-click=toggle_gold][phx-value-id='#{t.id}']") |> render_click()
    assert is_nil(Tracks.get(t.id).gold_manual)
  end

  @tag :tmp_dir
  test "apagar remove arquivo e registro", %{conn: conn, tmp_dir: root} do
    path = Path.join(root, "_Inbox/del.mp3")
    File.write!(path, "audio")

    t =
      insert(:track,
        status: :present,
        source_playlist: "youtube",
        rel_path: "_Inbox/del.mp3",
        filename: "del.mp3"
      )

    {:ok, view, _} = live(conn, ~p"/importados")
    view |> element("button[phx-click=delete][phx-value-id='#{t.id}']") |> render_click()

    refute File.exists?(path)
    assert is_nil(Tracks.get(t.id))
  end

  test "agrupa por playlist e só mostra as faixas ao expandir", %{conn: conn} do
    p = "https://youtube.com/playlist?list=ROLE"
    playlist_track("Faixa Um", p, 1, "Meu Rolê")
    playlist_track("Faixa Dois", p, 2, "Meu Rolê")

    {:ok, view, html} = live(conn, ~p"/importados")
    assert html =~ "Meu Rolê"
    assert html =~ "2 faixas"
    refute html =~ "Faixa Um"

    assert has_element?(
             view,
             "button[phx-click=toggle_playlist][aria-expanded=false]",
             "Meu Rolê"
           )

    html = view |> element("button[phx-click=toggle_playlist]", "Meu Rolê") |> render_click()
    assert has_element?(view, "button[phx-click=toggle_playlist][aria-expanded=true]", "Meu Rolê")
    assert html =~ "Faixa Um"
    assert html =~ "Faixa Dois"
  end

  test "vídeo avulso (sem playlist) aparece em Avulsas", %{conn: conn} do
    insert(:track,
      status: :present,
      source_playlist: "youtube",
      tag_title: "Solo",
      raw_tags: %{"youtube_url" => "https://youtu.be/x"}
    )

    {:ok, _view, html} = live(conn, ~p"/importados")
    assert html =~ "Avulsas"
    assert html =~ "Solo"
  end

  test "criar set gera um RecSet na ordem da playlist e navega pra ele", %{conn: conn} do
    p = "https://youtube.com/playlist?list=SET"
    playlist_track("A", p, 1, "Festa")
    playlist_track("B", p, 2, "Festa")

    {:ok, view, _} = live(conn, ~p"/importados")

    assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "create_set", %{"key" => p})
    assert to =~ ~r{^/set/}

    set = Sets.list() |> List.first()
    assert set.name == "Festa"
    assert Enum.map(Sets.entries(set), & &1.track.tag_title) == ~w(A B)
    # consecutive pairs auto-connected (the opener has no incoming transition)
    assert [%{transition: nil}, %{transition: %{"enabled" => true}}] = Sets.entries(set)
  end

  test "reviewing a watch link with a radio only queues the confirmed video", %{conn: conn} do
    url = "https://www.youtube.com/watch?v=ZvODpklNB2c"

    expect(Beatgrid.YouTube.DownloaderMock, :list_entries, fn ^url ->
      {:ok, [%{id: "ZvODpklNB2c", title: "Mestre Zinho - Queijinho do amor", url: url}]}
    end)

    {:ok, view, _} = live(conn, ~p"/importados")

    view
    |> form("#link-preview", %{urls: url <> "&list=RDZvODpklNB2c&start_radio=1"})
    |> render_submit()

    assert render_async(view) =~ "Mestre Zinho - Queijinho do amor"
    refute_enqueued(worker: Beatgrid.Workers.DownloadWorker)
    refute_enqueued(worker: Beatgrid.Workers.ExpandWorker)
    view |> form("#confirm-downloads") |> render_submit()
    assert_enqueued(worker: Beatgrid.Workers.DownloadWorker, args: %{url: url, playlist_url: nil})
    assert has_element?(view, "#download-activity", "Na fila")
    batch_url = assert_patch(view)
    assert batch_url =~ "/importados?lote="

    view |> element("#import-sources a", "Pasta ou arquivo") |> render_click()
    assert_patch(view, ~p"/importados?origem=local")
    refute has_element?(view, "#download-activity")

    view |> element("#import-sources a", "YouTube e Spotify") |> render_click()
    assert_patch(view, batch_url)
    assert has_element?(view, "#download-activity", "Queijinho do amor")

    {:ok, reloaded, _} = live(conn, batch_url)
    assert has_element?(reloaded, "#download-activity", "Queijinho do amor")
  end

  test "a reviewed subset preserves its original playlist positions", %{conn: conn} do
    url = "https://www.youtube.com/playlist?list=PLabc"

    entries =
      for {id, title} <- [{"aaaaaaaaaaa", "Primeira"}, {"bbbbbbbbbbb", "Segunda"}] do
        %{
          id: id,
          title: title,
          url: "https://www.youtube.com/watch?v=" <> id,
          playlist_title: "Festa"
        }
      end

    expect(Beatgrid.YouTube.DownloaderMock, :list_entries, fn ^url -> {:ok, entries} end)
    {:ok, view, _} = live(conn, ~p"/importados")
    view |> form("#link-preview", %{urls: url}) |> render_submit()
    assert render_async(view) =~ "Festa"
    refute has_element?(view, "#confirm-downloads input[checked]")
    assert has_element?(view, "#confirm-downloads button[type=submit][disabled]")
    view |> element("#playlist-selection", "Selecionar todas") |> render_click()
    assert has_element?(view, "#confirm-downloads input[value=aaaaaaaaaaa][checked]")
    assert has_element?(view, "#confirm-downloads input[value=bbbbbbbbbbb][checked]")
    refute_enqueued(worker: Beatgrid.Workers.DownloadWorker)
    view |> element("#playlist-selection", "Limpar seleção") |> render_click()
    refute has_element?(view, "#confirm-downloads input[checked]")
    render_submit(view, "confirm_downloads", %{"ids" => ["bbbbbbbbbbb", "unreviewed"]})
    assert [job] = all_enqueued(worker: Beatgrid.Workers.DownloadWorker)
    assert job.args["playlist_index"] == 2
    assert job.args["video_id"] == "bbbbbbbbbbb"
  end

  test "a second batch follows an already queued video without starting another job", %{
    conn: conn
  } do
    url = "https://www.youtube.com/watch?v=ZvODpklNB2c"

    stub(Beatgrid.YouTube.DownloaderMock, :list_entries, fn ^url ->
      {:ok, [%{id: "ZvODpklNB2c", title: "Queijinho", url: url}]}
    end)

    for _ <- 1..2 do
      {:ok, view, _} = live(conn, ~p"/importados")
      view |> form("#link-preview", %{urls: url}) |> render_submit()
      render_async(view)
      view |> form("#confirm-downloads") |> render_submit()
      assert_patch(view)
      assert has_element?(view, "#download-activity", "Queijinho")
    end

    assert [_] = all_enqueued(worker: Beatgrid.Workers.DownloadWorker)
  end

  test "Spotify references offer concrete video versions with no automatic selection", %{
    conn: conn
  } do
    expect(Beatgrid.Spotify.PlaylistMock, :fetch, fn "2qq0JHZ3xzT6YNlVAWIr73" ->
      {:ok,
       %{
         title: "balanço venenoso",
         tracks: [%{artist: "Joaozinho Do Exu", title: "Queijinho do Amor"}]
       }}
    end)

    expect(
      Beatgrid.YouTube.DownloaderMock,
      :list_entries,
      fn "ytsearch3:Joaozinho Do Exu Queijinho do Amor" ->
        {:ok, [%{id: "aaaaaaaaaaa", title: "Versão ao vivo", playlist_title: "Resultados"}]}
      end
    )

    {:ok, view, _} = live(conn, ~p"/importados")

    view
    |> form("#link-preview", %{urls: "https://open.spotify.com/playlist/2qq0JHZ3xzT6YNlVAWIr73"})
    |> render_submit()

    assert render_async(view) =~ "balanço venenoso"
    view |> element("button[phx-click=find_version]") |> render_click()
    assert render_async(view) =~ "Versão ao vivo"
    assert has_element?(view, "#confirm-downloads button[disabled]", "Baixar 0 faixas")
    refute has_element?(view, "#confirm-downloads input[checked]")
    refute_enqueued(worker: Beatgrid.Workers.DownloadWorker)

    render_change(
      form(view, "#link-preview", %{urls: "https://www.youtube.com/watch?v=ZvODpklNB2c"})
    )

    refute has_element?(view, "#confirm-downloads")
    refute has_element?(view, "button[phx-click=find_version]")
  end

  @tag :tmp_dir
  test "Spotify filters retain the original track, library link and review context", %{
    conn: conn,
    tmp_dir: root
  } do
    track = insert(:track, status: :present, norm_title: "primeira", norm_artist: "trio")
    File.write!(Path.join(root, track.rel_path), "audio")
    url = "https://open.spotify.com/playlist/2qq0JHZ3xzT6YNlVAWIr73"

    expect(Beatgrid.Spotify.PlaylistMock, :fetch, fn _ ->
      {:ok,
       %{
         title: "No baile",
         tracks: [
           %{artist: "Trio", title: "Primeira"},
           %{artist: "Banda", title: "Segunda"}
         ]
       }}
    end)

    stub(Beatgrid.YouTube.DownloaderMock, :list_entries, fn "ytsearch3:Banda Segunda" ->
      {:ok, [%{id: "aaaaaaaaaaa", title: "Segunda ao vivo"}]}
    end)

    {:ok, view, _} = live(conn, ~p"/importados")
    view |> form("#link-preview", %{urls: url}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#spotify-tracks a[href='/track/#{track.id}']")
    view |> element("#spotify-filters button", "Faltam") |> render_click()
    assert has_element?(view, "#spotify-filters [aria-pressed=true]", "Faltam 1")
    refute has_element?(view, "#spotify-tracks", "Primeira")
    view |> element("#spotify-version-1") |> render_click()
    render_async(view)
    assert has_element?(view, "#spotify-version-heading", "Segunda")
    refute has_element?(view, "#spotify-tracks")
    assert has_element?(view, "#confirm-downloads input[value=aaaaaaaaaaa]:not(:checked)")

    view |> element("#back-to-spotify") |> render_click()
    refute has_element?(view, "#confirm-downloads")
    assert has_element?(view, "#spotify-filters [aria-pressed=true]", "Faltam 1")
    assert has_element?(view, "#spotify-version-1")
    refute_enqueued(worker: Beatgrid.Workers.DownloadWorker)

    view |> element("#spotify-version-1") |> render_click()
    render_async(view)
    render_submit(view, "confirm_downloads", %{"ids" => ["aaaaaaaaaaa"]})
    assert_patch(view)
    assert has_element?(view, "#spotify-version-1")
    assert has_element?(view, "#link-preview textarea", url)
    assert_enqueued(worker: Beatgrid.Workers.DownloadWorker, args: %{video_id: "aaaaaaaaaaa"})
  end

  test "hostile sort/filter payloads are ignored, never crash the view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/importados")

    render_click(view, "sort", %{"by" => "not_an_existing_atom_xyz"})
    render_click(view, "toggle_filter", %{"key" => "delete"})

    assert has_element?(view, "h1", "Importações")
  end
end
