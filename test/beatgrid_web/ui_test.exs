defmodule BeatgridWeb.UITest do
  use Beatgrid.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Beatgrid.Library.GenreFolders

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

  describe "format_views/1" do
    test "formata views em pt-BR" do
      assert BeatgridWeb.UI.format_views(nil) == "—"
      assert BeatgridWeb.UI.format_views(950) == "950"
      assert BeatgridWeb.UI.format_views(12_000) == "12 mil"
      assert BeatgridWeb.UI.format_views(2_300_000) == "2,3 mi"
    end
  end

  describe "format_age/1" do
    test "formata idade da publicação" do
      assert BeatgridWeb.UI.format_age(nil) == "—"
      today = Date.utc_today()
      assert BeatgridWeb.UI.format_age(today) == "este ano"
      assert BeatgridWeb.UI.format_age(Date.add(today, -800)) =~ "há 2 anos"
    end
  end

  describe "folder_color/1 and folder_label/1 DB fallback" do
    # The dynamic-key path reads GenreFolders.by_key/0 — a global cache the
    # sandbox can't roll back. Factory inserts bypass the invalidating context
    # writes, so each test starts (and leaves) the cache cold.
    setup do
      GenreFolders.invalidate()
      on_exit(fn -> GenreFolders.invalidate() end)
    end

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

    test "a folder write through the context refreshes the cached lookup" do
      # Warm the cache while the key is unknown…
      assert BeatgridWeb.UI.folder_label("samba2") == "samba2"

      # …then a context write must invalidate it, or the badge stays stale.
      {:ok, _} =
        GenreFolders.create(%{
          key: "samba2",
          display_name: "Samba Dois",
          dir_name: "Samba Dois"
        })

      assert BeatgridWeb.UI.folder_label("samba2") == "Samba Dois"
    end
  end
end
