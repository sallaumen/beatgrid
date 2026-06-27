defmodule BeatgridWeb.UITest do
  use Beatgrid.DataCase, async: true

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

  describe "cover_src/1 art trust" do
    test "shows art only when trusted and confidence isn't low" do
      song = %{image_url: "https://img/x.jpg"}

      assert BeatgridWeb.UI.cover_src(%{
               soundcharts_song: song,
               sc_art_trusted: true,
               sc_match_confidence: :high
             }) ==
               "https://img/x.jpg"

      assert BeatgridWeb.UI.cover_src(%{
               soundcharts_song: song,
               sc_art_trusted: false,
               sc_match_confidence: :high
             }) == nil

      assert BeatgridWeb.UI.cover_src(%{
               soundcharts_song: song,
               sc_art_trusted: true,
               sc_match_confidence: :low
             }) == nil

      assert BeatgridWeb.UI.cover_src(%{
               soundcharts_song: nil,
               sc_art_trusted: true,
               sc_match_confidence: :high
             }) == nil
    end
  end

  describe "cover_play/1" do
    test "overlays a play button that targets the global player" do
      html =
        render_component(&BeatgridWeb.UI.cover_play/1,
          play_src: "/audio/xyz",
          track_id: "xyz",
          artist: "Elis",
          size: 38
        )

      assert html =~ "beatgrid:play"
      assert html =~ "#player-audio"
      assert html =~ "xyz"
      assert html =~ "group-hover/cover"
    end
  end

  describe "folder_color/1 and folder_label/1 DB fallback" do
    test "uses the hardcoded fast path for seeded keys" do
      assert BeatgridWeb.UI.folder_color("mpb") == "#8b7bf0"
      assert BeatgridWeb.UI.folder_label("mpb") == "MPB"
    end

    test "falls back to a DB-present folder's color + display_name" do
      insert(:genre_folder,
        key: "samba",
        display_name: "Samba",
        dir_name: "Samba",
        color: "#abc123"
      )

      assert BeatgridWeb.UI.folder_color("samba") == "#abc123"
      assert BeatgridWeb.UI.folder_label("samba") == "Samba"
    end

    test "a totally-unknown key returns gray / the key, and nil stays a dash" do
      assert BeatgridWeb.UI.folder_color("ghost") == "#9498a6"
      assert BeatgridWeb.UI.folder_label("ghost") == "ghost"
      assert BeatgridWeb.UI.folder_label(nil) == "—"
    end
  end
end
