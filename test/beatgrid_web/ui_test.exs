defmodule BeatgridWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  describe "play_button/1" do
    test "dispatches beatgrid:play to the global player with src + id" do
      html =
        render_component(&BeatgridWeb.UI.play_button/1,
          src: "/audio/abc-123",
          track_id: "abc-123",
          preview: true
        )

      assert html =~ "beatgrid:play"
      assert html =~ "#player-audio"
      assert html =~ "abc-123"
    end
  end
end
