defmodule Beatgrid.SpotifyPlaylistTest do
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Spotify.{Embed, Playlist}

  test "recognizes shared and localized public playlist URLs" do
    id = "2qq0JHZ3xzT6YNlVAWIr73"
    assert {:ok, ^id} = Playlist.id("https://open.spotify.com/playlist/#{id}?si=123")
    assert {:ok, ^id} = Playlist.id("https://open.spotify.com/intl-pt/playlist/#{id}")
    assert :invalid = Playlist.id("https://example.com/playlist/#{id}")
  end

  @tag :tmp_dir
  test "matches a Spotify title to the playable library copy", %{tmp_dir: root} do
    previous = Application.fetch_env!(:beatgrid, :library_root)
    Application.put_env(:beatgrid, :library_root, root)
    on_exit(fn -> Application.put_env(:beatgrid, :library_root, previous) end)
    File.write!(Path.join(root, "local.mp3"), "music")

    track =
      insert(:track, rel_path: "local.mp3", norm_artist: "ze lima", norm_title: "toque tocador")

    expect(Beatgrid.Spotify.PlaylistMock, :fetch, fn _ ->
      {:ok, %{title: "balanço", tracks: [%{artist: "Zé Lima", title: "Toque Tocador"}]}}
    end)

    assert {:ok, %{tracks: [row]}} =
             Playlist.preview("2qq0JHZ3xzT6YNlVAWIr73")

    assert row.library_id == track.id
  end

  test "reads titles and artists in public preview order, without treating Spotify as audio" do
    data = %{
      "title" => "balanço venenoso",
      "trackList" => [
        %{"title" => "Queijinho do Amor", "subtitle" => "Joaozinho Do Exu"},
        %{"title" => "Toque Tocador", "subtitle" => "Zé Lima"}
      ]
    }

    json = Jason.encode!(%{props: %{pageProps: %{state: %{data: %{entity: data}}}}})

    Req.Test.stub(Embed, fn conn ->
      assert conn.request_path == "/embed/playlist/2qq0JHZ3xzT6YNlVAWIr73"
      Req.Test.html(conn, ~s(<script id="__NEXT_DATA__" type="application/json">#{json}</script>))
    end)

    assert {:ok, %{title: "balanço venenoso", tracks: [first, second]}} =
             Embed.fetch("2qq0JHZ3xzT6YNlVAWIr73", plug: {Req.Test, Embed})

    assert first == %{artist: "Joaozinho Do Exu", title: "Queijinho do Amor"}
    assert second.title == "Toque Tocador"
  end
end
