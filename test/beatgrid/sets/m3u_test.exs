defmodule Beatgrid.Sets.M3uTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Sets.M3u

  test "body renders the header plus an EXTINF pair per track" do
    tracks = [
      %{
        duration_ms: 183_500,
        tag_artist: "Djavan",
        tag_title: "Sina",
        filename: "Sina.mp3",
        rel_path: "MPB/Sina.mp3"
      },
      %{
        duration_ms: nil,
        tag_artist: nil,
        tag_title: nil,
        filename: "x.mp3",
        rel_path: "_Inbox/x.mp3"
      }
    ]

    body = M3u.body(tracks, "/root")

    assert body == """
           #EXTM3U
           #EXTINF:183,Djavan - Sina
           /root/MPB/Sina.mp3
           #EXTINF:-1,— - x.mp3
           /root/_Inbox/x.mp3
           """
  end

  test "filename swaps path-hostile characters and keeps the .m3u extension" do
    assert M3u.filename(~s{Sunset / B2B: "Vol. 1"?}) == "Sunset - B2B- -Vol. 1--.m3u"
    assert M3u.filename(nil) == "set.m3u"
  end

  test "multiline tags and empty titles keep one display line per track" do
    track = %{
      duration_ms: nil,
      tag_artist: "Duo\r\nAo Vivo",
      tag_title: "  ",
      filename: "Canção.mp3",
      rel_path: "MPB/Canção.mp3"
    }

    assert String.split(M3u.body([track], "/music"), "\n", trim: true) ==
             ["#EXTM3U", "#EXTINF:-1,Duo Ao Vivo - Canção.mp3", "/music/MPB/Canção.mp3"]
  end

  test "a long Unicode set name fits a filesystem component including the extension" do
    prefix = String.duplicate("São João ", 40)
    first = M3u.filename(prefix <> "Manhã")
    assert byte_size(first) <= 255
    assert String.valid?(first) and String.ends_with?(first, ".m3u")
    refute first == M3u.filename(prefix <> "Noite")
    assert M3u.filename("  ") == "set.m3u"
  end
end
