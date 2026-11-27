defmodule BeatgridWeb.RecSetNavigationTest do
  use BeatgridWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Beatgrid.Repo
  alias Beatgrid.Sets

  test "the compact picker opens the chosen set at its own URL", %{conn: conn} do
    {:ok, first} = Sets.create("Abertura")
    {:ok, second} = Sets.create("Segundo bloco")
    {:ok, view, _html} = live(conn, ~p"/set/#{first.id}")

    view |> form("#compact-set-picker", %{set_id: second.id}) |> render_change()
    assert_patch(view, ~p"/set/#{second.id}")
    assert has_element?(view, "#compact-set-picker option[selected][value='#{second.id}']")
    assert has_element?(view, "details summary", "Ferramentas do set")
    assert has_element?(view, "details button[phx-click=delete_set]")
    assert has_element?(view, "a[href='/discotecagem?set=#{second.id}']", "Abrir na discotecagem")
  end

  test "selecting a set updates the URL and reloads the same set", %{conn: conn} do
    {:ok, first} = Sets.create("Primeiro baile")
    {:ok, second} = Sets.create("Segundo baile")
    {:ok, view, _html} = live(conn, ~p"/set/#{first.id}")

    view |> element("a[href='/set/#{second.id}']", second.name) |> render_click()
    assert_patch(view, ~p"/set/#{second.id}")
    assert has_element?(view, "#set-name input[name=name][value='Segundo baile']")

    {:ok, refreshed, _html} = live(conn, ~p"/set/#{second.id}")
    assert has_element?(refreshed, "#set-name input[name=name][value='Segundo baile']")

    render_patch(view, ~p"/set/#{first.id}")
    assert has_element?(view, "#set-name input[name=name][value='Primeiro baile']")
  end

  test "malformed and deleted set links return to the set list", %{conn: conn} do
    {:ok, remaining} = Sets.create("Próximo baile")
    {:ok, deleted} = Sets.create("Encerrado")
    assert {:ok, _} = Sets.delete(deleted)

    for id <- ["nao-e-uuid", deleted.id] do
      assert {:error, {:live_redirect, %{to: "/set"}}} = result = live(conn, ~p"/set/#{id}")
      assert {:ok, view, _html} = follow_redirect(result, conn, ~p"/set")
      assert has_element?(view, "#set-name input[name=name][value='#{remaining.name}']")
    end
  end

  test "edits a name on its own set and ignores a delayed edit from the previous set", %{
    conn: conn
  } do
    {:ok, first} = Sets.create("Primeiro baile")
    {:ok, second} = Sets.create("Segundo baile")
    {:ok, view, _html} = live(conn, ~p"/set/#{first.id}")

    for invalid <- [" ", String.duplicate("a", 256)] do
      view |> form("#set-name", %{name: invalid}) |> render_change()
      assert has_element?(view, "#set-name input[aria-invalid=true]")
      assert Sets.get(first.id).name == first.name
    end

    view |> form("#set-name", %{name: "Baile de sexta"}) |> render_submit()
    refute has_element?(view, "#set-name input[aria-invalid=true]")
    assert Sets.get(first.id).name == "Baile de sexta"

    render_patch(view, ~p"/set/#{second.id}")
    render_change(view, "rename", %{"set_id" => first.id, "name" => "Nome atrasado"})
    assert has_element?(view, "#set-name input[name=name][value='Segundo baile']")
    assert Sets.get(second.id).name == second.name
  end

  test "deleting the selected set moves to a surviving URL or the empty editor", %{conn: conn} do
    {:ok, remaining} = Sets.create("Próximo baile")
    {:ok, deleted} = Sets.create("Encerrado")
    {:ok, view, _html} = live(conn, ~p"/set/#{deleted.id}")

    view |> element("button[phx-click=delete_set]") |> render_click()
    assert_patch(view, ~p"/set/#{remaining.id}")
    assert has_element?(view, "#set-name input[name=name][value='#{remaining.name}']")
    assert is_nil(Sets.get(deleted.id))

    view |> element("button[phx-click=delete_set]") |> render_click()
    assert_patch(view, ~p"/set")
    refute has_element?(view, "#set-name")
  end

  test "creating and duplicating a set puts the new selection in the URL", %{conn: conn} do
    {:ok, existing} = Sets.create("Baile")
    {:ok, view, _html} = live(conn, ~p"/set/#{existing.id}")

    view |> element("button[phx-click=new_set]") |> render_click()
    assert new_path = assert_patch(view)
    assert "/set/" <> new_id = new_path
    assert %{name: "Novo set"} = Sets.get(new_id)

    view |> element("button[phx-click=duplicate_set]") |> render_click()
    assert copy_path = assert_patch(view)
    assert "/set/" <> copy_id = copy_path
    assert copy_id != new_id
    assert %{name: "Novo set (cópia)"} = Sets.get(copy_id)
  end

  test "a rename from an editor whose set was deleted opens the remaining set", %{conn: conn} do
    {:ok, remaining} = Sets.create("Próximo baile")
    {:ok, deleted} = Sets.create("Encerrado")
    {:ok, view, _html} = live(conn, ~p"/set/#{deleted.id}")
    Repo.delete!(deleted)

    view |> form("#set-name", %{name: "Nome atrasado"}) |> render_submit()
    assert_patch(view, ~p"/set/#{remaining.id}")
    assert has_element?(view, "#set-name input[name=name][value='#{remaining.name}']")
  end

  test "a stale delete event cannot delete the set selected after it", %{conn: conn} do
    {:ok, first} = Sets.create("Primeiro baile")
    {:ok, second} = Sets.create("Segundo baile")
    {:ok, view, _html} = live(conn, ~p"/set/#{second.id}")

    render_click(view, "delete_set", %{"id" => first.id})
    assert has_element?(view, "#set-name input[name=name][value='Segundo baile']")
    assert Sets.get(second.id)
  end

  test "a plan completion leaves a different selected set and its running job alone" do
    old_id = Ecto.UUID.generate()
    current_id = Ecto.UUID.generate()

    socket =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{},
        set: %{id: current_id},
        planning_sets: MapSet.new([old_id, current_id])
      )

    assert {:noreply, updated} =
             BeatgridWeb.RecSetLive.handle_async(
               {:plan, old_id, "planejado"},
               {:ok, {:ok, %{id: old_id}}},
               socket
             )

    assert updated.assigns.set.id == current_id
    assert updated.assigns.planning_sets == MapSet.new([current_id])
  end
end
