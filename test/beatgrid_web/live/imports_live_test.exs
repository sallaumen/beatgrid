defmodule BeatgridWeb.ImportsLiveTest do
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Sets

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

    html = render_click(view, "toggle_playlist", %{"key" => p})
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

  test "botão importar revela o form e o submit dá o retorno de baixando", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/importados")
    refute has_element?(view, "form[phx-submit=import_playlist]")

    view |> element("button[phx-click=toggle_import]") |> render_click()
    assert has_element?(view, "form[phx-submit=import_playlist]")

    view
    |> form("form[phx-submit=import_playlist]", %{"url" => "https://youtube.com/playlist?list=X"})
    |> render_submit()

    # the success path enqueues the download and closes the form (the enqueue
    # itself is covered in YouTubeTest)
    refute has_element?(view, "form[phx-submit=import_playlist]")
  end
end
