defmodule Beatgrid.Soundcharts.HttpTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Soundcharts.{Http, Response}

  describe "search_song/1" do
    test "parses items and the x-quota-remaining header" do
      Req.Test.stub(Http, fn conn ->
        assert conn.request_path == "/api/v2/song/search/Disritmia"

        conn
        |> Plug.Conn.put_resp_header("x-quota-remaining", "987")
        |> Req.Test.json(%{
          "items" => [
            %{
              "uuid" => "u1",
              "name" => "Disritmia",
              "creditName" => "Casuarina",
              "releaseDate" => "2010-01-05T00:00:00+00:00"
            }
          ],
          "page" => %{"total" => 1}
        })
      end)

      assert {:ok, %Response{data: [item], quota_remaining: 987, status: 200}} =
               Http.search_song("Disritmia")

      assert item.uuid == "u1"
      assert item.credit_name == "Casuarina"
      assert item.release_date == ~D[2010-01-05]
    end
  end

  describe "get_song/1" do
    test "parses the audio block, isrc, label and genres into song attrs" do
      Req.Test.stub(Http, fn conn ->
        assert conn.request_path == "/api/v2.25/song/u1"

        conn
        |> Plug.Conn.put_resp_header("x-quota-remaining", "986")
        |> Req.Test.json(%{
          "type" => "song",
          "object" => %{
            "uuid" => "u1",
            "name" => "Disritmia",
            "creditName" => "Casuarina",
            "isrc" => %{"value" => "BRKMM0900046"},
            "releaseDate" => "2010-01-05T00:00:00+00:00",
            "duration" => 215,
            "languageCode" => "pt-BR",
            "imageUrl" => "https://img/x.jpg",
            "mainArtists" => [%{"uuid" => "artist-uuid", "name" => "Casuarina"}],
            "genres" => [%{"root" => "latin", "sub" => ["forró", "samba"]}],
            "labels" => [%{"name" => "Agente Digital", "type" => "main"}],
            "audio" => %{
              "tempo" => 141.57,
              "key" => 11,
              "mode" => 0,
              "energy" => 0.63,
              "valence" => 0.87,
              "danceability" => 0.72,
              "loudness" => -7.2,
              "timeSignature" => 4
            }
          }
        })
      end)

      assert {:ok, %Response{data: attrs, quota_remaining: 986, status: 200}} =
               Http.get_song("u1")

      assert attrs.sc_uuid == "u1"
      assert attrs.isrc == "BRKMM0900046"
      assert attrs.release_date == ~D[2010-01-05]
      assert attrs.label == "Agente Digital"
      assert attrs.genres == ["latin"]
      assert attrs.subgenres == ["forró", "samba"]
      assert attrs.tempo_bpm == 141.57
      assert attrs.music_key == 11
      assert attrs.music_mode == 0
      assert attrs.energy == 0.63
      assert attrs.loudness == -7.2
      assert attrs.duration_seconds == 215
      assert attrs.time_signature == 4
      assert attrs.language_code == "pt-BR"
      assert attrs.image_url == "https://img/x.jpg"
      assert attrs.sc_artist_uuid == "artist-uuid"
      assert attrs.sc_artist_name == "Casuarina"
    end
  end

  test "a non-2xx response becomes an :error tuple" do
    Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
    assert {:error, {:http_error, 404, _body}} = Http.search_song("nope")
  end
end
