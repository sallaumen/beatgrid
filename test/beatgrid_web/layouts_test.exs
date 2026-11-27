defmodule BeatgridWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "reconnection notices keep their horizontal flex layout when revealed" do
    document =
      render_component(&BeatgridWeb.Layouts.flash_group/1, flash: %{})
      |> LazyHTML.from_fragment()

    for {id, error_class} <- [
          {"client-error", "phx-client-error"},
          {"server-error", "phx-server-error"}
        ] do
      notice = LazyHTML.query(document, "##{id}")
      [commands] = LazyHTML.attribute(notice, "phx-disconnected")
      selector = ".#{error_class} ##{id}"

      assert [["show", %{"display" => "flex", "to" => ^selector}], ["remove_attr", _]] =
               Jason.decode!(commands)
    end
  end
end
