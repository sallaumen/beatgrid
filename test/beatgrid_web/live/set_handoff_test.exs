defmodule BeatgridWeb.SetHandoffTest do
  use BeatgridWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Beatgrid.Sets

  test "open the selected set in the booth without starting playback", %{conn: conn} do
    {:ok, set} = Sets.create("Set da noite")
    {:ok, editor, _} = live(conn, ~p"/set/#{set.id}")
    destination = ~p"/discotecagem?set=#{set.id}"
    assert has_element?(editor, "main a[href='#{destination}']", "Abrir na discotecagem")
    {:ok, booth, _} = live(conn, destination)
    assert has_element?(booth, "#dj-set-picker option[value='#{set.id}'][selected]")
    refute_push_event(booth, "dj_load", _)
  end

  test "an invalid handoff opens the booth with no set selected", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/discotecagem?set=invalid")
    refute has_element?(view, "#dj-set-picker option[selected]")
    assert has_element?(view, "#dj-audio-a")
  end
end
