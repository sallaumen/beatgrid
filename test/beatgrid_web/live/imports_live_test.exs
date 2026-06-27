defmodule BeatgridWeb.ImportsLiveTest do
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  test "lista só faixas do youtube", %{conn: conn} do
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

    {:ok, _view, html} = live(conn, ~p"/importados")
    assert html =~ "Do Tubo"
    refute html =~ "Do Disco"
  end

  test "toggle Ouro marca manual", %{conn: conn} do
    t = insert(:track, status: :present, source_playlist: "youtube", tag_title: "Marcar")

    {:ok, view, _} = live(conn, ~p"/importados")
    view |> element("button[phx-click=toggle_gold][phx-value-id='#{t.id}']") |> render_click()

    assert Tracks.get(t.id).gold_manual == true
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
end
