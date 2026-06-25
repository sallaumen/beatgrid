defmodule Beatgrid.Audio.MetadataTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.Metadata

  @mp3_with_cover %{
    "streams" => [
      # mp3s with embedded cover art carry a video (mjpeg/png) stream too —
      # the parser must pick the audio stream, not streams[0].
      %{"codec_type" => "video", "codec_name" => "mjpeg"},
      %{
        "codec_type" => "audio",
        "sample_rate" => "44100",
        "channels" => 2,
        "bit_rate" => "320000"
      }
    ],
    "format" => %{
      "format_name" => "mp3",
      "duration" => "138.360000",
      "bit_rate" => "320000",
      "tags" => %{
        "title" => "Carcará",
        "artist" => "Joao Do Vale/Chico Buarque",
        "album" => "Carcará",
        "date" => "1965",
        "track" => "3/12",
        "TSRC" => "BRABC0000001"
      }
    }
  }

  describe "from_ffprobe/1" do
    test "parses streams, format and tags from a typical mp3" do
      assert {:ok, %Metadata{} = m} = Metadata.from_ffprobe(@mp3_with_cover)

      assert m.duration_ms == 138_360
      assert m.bitrate_kbps == 320
      assert m.sample_rate_hz == 44_100
      assert m.channels == 2
      assert m.format_name == "mp3"
      assert m.title == "Carcará"
      assert m.artist == "Joao Do Vale/Chico Buarque"
      assert m.album == "Carcará"
      assert m.year == 1965
      assert m.track_no == 3
      assert m.isrc == "BRABC0000001"
      assert m.genre == nil
    end

    test "returns {:error, :not_audio} when there is no audio stream" do
      json = %{
        "streams" => [%{"codec_type" => "video"}],
        "format" => %{"format_name" => "image2"}
      }

      assert {:error, :not_audio} = Metadata.from_ffprobe(json)
    end

    test "tolerates missing tags and missing bitrate" do
      json = %{
        "streams" => [%{"codec_type" => "audio", "sample_rate" => "44100", "channels" => 2}],
        "format" => %{"format_name" => "mp3", "duration" => "10.0"}
      }

      assert {:ok, m} = Metadata.from_ffprobe(json)
      assert m.duration_ms == 10_000
      assert m.bitrate_kbps == nil
      assert m.title == nil
      assert m.isrc == nil
    end

    test "looks tags up case-insensitively and keeps the raw tag map" do
      json = %{
        "streams" => [%{"codec_type" => "audio"}],
        "format" => %{"tags" => %{"TITLE" => "Ben", "Artist" => "Jorge Ben"}}
      }

      assert {:ok, m} = Metadata.from_ffprobe(json)
      assert m.title == "Ben"
      assert m.artist == "Jorge Ben"
      assert m.raw_tags == %{"TITLE" => "Ben", "Artist" => "Jorge Ben"}
    end
  end
end
