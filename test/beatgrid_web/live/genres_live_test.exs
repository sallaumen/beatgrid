defmodule BeatgridWeb.GenresLiveTest do
  # async: false — "Preencher com IA" runs a start_async task that talks to the
  # (globally stubbed) AI mock and the shared sandbox.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory
  import Mox

  alias Beatgrid.Library.GenreFolders

  setup :set_mox_global

  test "links directly to the classification queue", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/generos")
    assert has_element?(view, "a[href='/revisao?aba=classifications']", "Revisar classificações")

    {:ok, review, _html} = live(conn, ~p"/revisao?aba=classifications")
    assert has_element?(review, "a[href='/revisao?aba=classifications'][aria-current=page]")
  end

  test "lists folders and saves an edited description", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "old")

    {:ok, view, html} = live(conn, ~p"/generos")
    assert html =~ "Gêneros"
    assert html =~ "MPB"
    assert has_element?(view, "#genre-mpb p", "old")
    refute has_element?(view, "#folder-mpb textarea")

    view
    |> element("#genre-mpb button[phx-click=edit_description]", "Editar descrição")
    |> render_click()

    assert has_element?(view, "#folder-mpb textarea", "old")

    view
    |> form("#folder-mpb", %{description: "Songwriter MPB; voz+violão."})
    |> render_submit()

    assert GenreFolders.get_by_key("mpb").description == "Songwriter MPB; voz+violão."
    refute has_element?(view, "#folder-mpb textarea")
    assert has_element?(view, "#genre-mpb p", "Songwriter MPB; voz+violão.")
  end

  test "renders multiline criteria without template indentation", %{conn: conn} do
    description = "Primeira linha\n  Segunda linha"

    insert(:genre_folder,
      key: "mpb",
      display_name: "MPB",
      dir_name: "MPB",
      description: description
    )

    {:ok, _view, html} = live(conn, ~p"/generos")

    assert html =~ ">#{description}</p>"
    assert GenreFolders.get_by_key("mpb").description == description
  end

  test "creating via the form adds a folder", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/generos")

    refute has_element?(view, "#new-genre")
    view |> element("#open-new-genre") |> render_click()

    html =
      view
      |> form("#new-genre", %{display_name: "Forró Pé de Serra", color: "#abc123"})
      |> render_submit()

    assert html =~ "Forró Pé de Serra"
    refute has_element?(view, "#new-genre")

    folder = GenreFolders.get_by_key("forro_pe_de_serra")
    assert folder
    assert folder.display_name == "Forró Pé de Serra"
    assert folder.dir_name == "Forró Pé de Serra"
    assert folder.color == "#abc123"
  end

  test "deleting an empty folder removes it", %{conn: conn} do
    insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")

    {:ok, view, html} = live(conn, ~p"/generos")
    assert html =~ "Samba"

    html =
      view
      |> element(~s(button[phx-click="delete_genre"][phx-value-key="samba"]))
      |> render_click()

    refute html =~ "Samba"
    assert GenreFolders.get_by_key("samba") == nil
  end

  test "deleting an in-use folder shows the in-use toast and keeps it", %{conn: conn} do
    insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")
    insert(:track, genre_folder: "samba", status: :present)

    {:ok, view, _html} = live(conn, ~p"/generos")

    # the delete control is disabled while in use; drive the event directly
    html = render_click(view, "delete_genre", %{"key" => "samba"})

    assert html =~ "em uso"
    assert GenreFolders.get_by_key("samba")
  end

  test "AI suggests a separate rubric without overwriting the typed draft", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "")

    stub(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok,
       %{
         "description" => "Songwriter-driven Brazilian popular music.",
         "rationale" => "voz e violão no centro"
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/generos")

    view |> element("#genre-mpb button[phx-click=edit_description]") |> render_click()

    view |> form("#folder-mpb", %{description: "Minha proposta"}) |> render_change()

    view
    |> element(~s(button[phx-click="suggest_description"][phx-value-key="mpb"]))
    |> render_click()

    html = render_async(view)

    assert html =~ "Songwriter-driven Brazilian popular music."
    assert has_element?(view, "#folder-mpb textarea", "Minha proposta")
    assert has_element?(view, "#suggestion-mpb", "Songwriter-driven Brazilian popular music.")
    assert GenreFolders.get_by_key("mpb").description == ""

    view |> element("#apply-suggestion-mpb") |> render_click()

    assert has_element?(
             view,
             "#folder-mpb textarea",
             "Songwriter-driven Brazilian popular music."
           )

    view |> element("#folder-mpb button[phx-click=cancel_edit]", "Cancelar") |> render_click()
    refute has_element?(view, "#folder-mpb textarea")
    refute render(view) =~ "Songwriter-driven Brazilian popular music."
    view |> element("#genre-mpb button[phx-click=edit_description]") |> render_click()
    refute has_element?(view, "#folder-mpb textarea", "Minha proposta")
  end

  test "duplicate create retains values and cancel clears the draft", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")
    {:ok, view, _html} = live(conn, ~p"/generos")

    view |> element("#open-new-genre") |> render_click()
    view |> form("#new-genre", %{display_name: "MPB", color: "#abcdef"}) |> render_submit()

    assert has_element?(view, "#new-genre [role=alert]", "Já existe um gênero com esse nome.")
    assert has_element?(view, "#new-genre-name[value='MPB']")
    assert has_element?(view, "#new-genre input[name=color][value='#abcdef']")

    view |> element("#new-genre button[phx-click=cancel_create]") |> render_click()
    refute has_element?(view, "#new-genre")
    view |> element("#open-new-genre") |> render_click()
    assert has_element?(view, "#new-genre-name[value='']")
    assert has_element?(view, "#new-genre input[name=color][value='#9498a6']")
  end

  test "AI error keeps the unsaved description and allows retry", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "old")
    stub(Beatgrid.AI.Mock, :complete, fn _, _, _ -> {:error, :timeout} end)
    {:ok, view, _html} = live(conn, ~p"/generos")
    view |> element("#genre-mpb button[phx-click=edit_description]") |> render_click()
    view |> form("#folder-mpb", %{description: "Meu critério"}) |> render_change()
    view |> element("#folder-mpb button[phx-click=suggest_description]") |> render_click()
    render_async(view)
    assert has_element?(view, "#folder-mpb [role=alert]", "Falha ao gerar")
    assert has_element?(view, "#folder-mpb textarea", "Meu critério")
    refute has_element?(view, "#folder-mpb button[phx-click=suggest_description][disabled]")
    assert GenreFolders.get_by_key("mpb").description == "old"
  end

  test "a save failure leaves the submitted criteria in the editor", %{conn: conn} do
    folder =
      insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "old")

    {:ok, view, _html} = live(conn, ~p"/generos")
    view |> element("#genre-mpb button[phx-click=edit_description]") |> render_click()
    assert {:ok, _} = GenreFolders.delete(folder)
    view |> form("#folder-mpb", %{description: "Meu critério não salvo"}) |> render_submit()
    assert has_element?(view, "#folder-mpb [role=alert]", "Falha ao salvar")
    assert has_element?(view, "#folder-mpb textarea", "Meu critério não salvo")
  end

  test "a late response cannot alter a new edit after cancellation", %{conn: conn} do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB", description: "old")
    test = self()

    stub(Beatgrid.AI.Mock, :complete, fn _, _, _ ->
      send(test, {:started, self()})

      receive do
        :finish -> {:ok, %{"description" => "Obsolete suggestion", "rationale" => "Late"}}
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/generos")
    view |> element("#genre-mpb button[phx-click=edit_description]") |> render_click()
    view |> element("#folder-mpb button[phx-click=suggest_description]") |> render_click()
    assert_receive {:started, worker}
    view |> element("#folder-mpb button[phx-click=cancel_edit]") |> render_click()
    view |> element("#genre-mpb button[phx-click=edit_description]") |> render_click()
    view |> form("#folder-mpb", %{description: "Novo rascunho"}) |> render_change()
    send(worker, :finish)
    render_async(view)

    refute has_element?(view, "#suggestion-mpb")
    assert has_element?(view, "#folder-mpb textarea", "Novo rascunho")
    assert GenreFolders.get_by_key("mpb").description == "old"
  end
end
