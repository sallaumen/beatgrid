defmodule Beatgrid.Playback.NowPlayingTest do
  # async: false — a single global pointer shared across the node.
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

  test "losing the process that owns the audio clears the highlight in other tabs" do
    NowPlaying.subscribe()

    owner =
      spawn(fn ->
        NowPlaying.put(%{track_id: "gone", set_id: nil})
        Process.sleep(:infinity)
      end)

    assert_receive {:now_playing, %{track_id: "gone"}}
    Process.exit(owner, :kill)
    assert_receive {:now_playing, %{track_id: nil, set_id: nil}}
    assert NowPlaying.get() == %{track_id: nil, set_id: nil}
  end

  test "detaching a set updates the current owner's matching pointer only" do
    pointer = %{track_id: "t1", set_id: "s1"}
    NowPlaying.put(pointer)
    NowPlaying.subscribe()

    assert :ok = NowPlaying.detach_set("s2", "t1")
    assert :ok = NowPlaying.detach_set("s1", "t2")
    assert NowPlaying.get() == pointer
    refute_receive {:now_playing, _}, 50

    assert :ok = NowPlaying.detach_set("s1", "t1")
    assert NowPlaying.get() == %{track_id: "t1", set_id: nil}
    assert_receive {:now_playing, %{track_id: "t1", set_id: nil}}
  end

  test "a previous owner cannot detach an identical pointer claimed by another player" do
    pointer = %{track_id: "t1", set_id: "s1"}
    NowPlaying.put(pointer)
    parent = self()

    owner =
      spawn(fn ->
        NowPlaying.put(pointer)
        send(parent, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(owner, :stop) end)
    assert_receive :claimed

    assert :ok = NowPlaying.detach_set("s1", "t1")
    assert NowPlaying.get() == pointer
  end

  test "clear resets the pointer and broadcasts the empty state" do
    NowPlaying.put(%{track_id: "t3", set_id: "s3"})
    NowPlaying.subscribe()
    NowPlaying.clear()
    assert NowPlaying.get() == %{track_id: nil, set_id: nil}
    assert_receive {:now_playing, %{track_id: nil, set_id: nil}}
  end
end
