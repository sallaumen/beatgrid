defmodule Beatgrid.Library.TrackTest do
  use Beatgrid.DataCase, async: true

  import Beatgrid.Factory

  alias Beatgrid.Library.{Track, Tracks}

  test "sc_art_trusted defaults to true and is updatable" do
    track = insert(:track, status: :present)
    assert track.sc_art_trusted == true

    assert {:ok, updated} = Tracks.update(track, %{sc_art_trusted: false})
    assert updated.sc_art_trusted == false
  end

  test "casts the gold + youtube fields" do
    cs =
      Track.changeset(%Track{}, %{
        rel_path: "_Inbox/a.mp3",
        filename: "a.mp3",
        format: :mp3,
        gold_status: :candidate,
        gold_manual: true,
        youtube_views: 1_234_567,
        youtube_published_at: ~D[2020-01-01]
      })

    assert cs.valid?
    assert get_change(cs, :gold_status) == :candidate
    assert get_change(cs, :gold_manual) == true
    assert get_change(cs, :youtube_views) == 1_234_567
    assert get_change(cs, :youtube_published_at) == ~D[2020-01-01]
  end
end
