defmodule Beatgrid.Playback.NowPlayingTest do
  # async: false — a single global Agent shared across the node.
  use ExUnit.Case, async: false

  alias Beatgrid.Playback.NowPlaying

  setup do
    NowPlaying.clear()
    on_exit(&NowPlaying.clear/0)
    :ok
  end

  test "put sets the pointer and get reads it back" do
    NowPlaying.put(%{track_id: "t1", set_id: "s1"})
    assert NowPlaying.get() == %{track_id: "t1", set_id: "s1"}
  end

  test "put broadcasts {:now_playing, state} to subscribers" do
    NowPlaying.subscribe()
    NowPlaying.put(%{track_id: "t2", set_id: nil})
    assert_receive {:now_playing, %{track_id: "t2", set_id: nil}}
  end

  test "put does not broadcast when the pointer is unchanged" do
    NowPlaying.put(%{track_id: "t2", set_id: nil})
    NowPlaying.subscribe()

    NowPlaying.put(%{track_id: "t2", set_id: nil})

    refute_receive {:now_playing, _}, 50
  end

  test "clear resets the pointer and broadcasts the empty state" do
    NowPlaying.put(%{track_id: "t3", set_id: "s3"})
    NowPlaying.subscribe()
    NowPlaying.clear()
    assert NowPlaying.get() == %{track_id: nil, set_id: nil}
    assert_receive {:now_playing, %{track_id: nil, set_id: nil}}
  end
end
