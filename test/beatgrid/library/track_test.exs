defmodule Beatgrid.Library.TrackTest do
  use Beatgrid.DataCase, async: true

  import Beatgrid.Factory

  alias Beatgrid.Library.Tracks

  test "sc_art_trusted defaults to true and is updatable" do
    track = insert(:track, status: :present)
    assert track.sc_art_trusted == true

    assert {:ok, updated} = Tracks.update(track, %{sc_art_trusted: false})
    assert updated.sc_art_trusted == false
  end
end
