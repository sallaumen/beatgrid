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
end
