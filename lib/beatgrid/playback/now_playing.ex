defmodule Beatgrid.Playback.NowPlaying do
  @moduledoc """
  The app-wide "now playing" pointer: which track (and, if any, which set) is loaded
  in the global player. A tiny `Agent` (single-user, single-node app) so every
  LiveView can read it **on mount** (`get/0`) and stay in sync via a PubSub broadcast
  (`subscribe/0`). Holds only `%{track_id, set_id}` — the *pointer*, never a track
  list; play/pause is transient client state and intentionally not stored here.
  """
  use Agent

  alias Phoenix.PubSub

  @topic "now_playing"
  # Cue-point marker changes go on their OWN topic so the many now-playing subscribers
  # (Library/RecSet/Review highlight rows) don't get messages they don't handle — only
  # the player and the track page subscribe here.
  @markers_topic "markers"
  @empty %{track_id: nil, set_id: nil}

  def start_link(_opts), do: Agent.start_link(fn -> @empty end, name: __MODULE__)

  @doc "Current pointer: `%{track_id, set_id}` (either may be nil)."
  @spec get() :: %{track_id: term() | nil, set_id: term() | nil}
  def get, do: Agent.get(__MODULE__, & &1)

  @doc "Set the pointer and broadcast `{:now_playing, state}` on the topic. Returns the state."
  @spec put(%{optional(:track_id) => term(), optional(:set_id) => term()}) :: %{
          track_id: term() | nil,
          set_id: term() | nil
        }
  def put(state) do
    norm = %{track_id: state[:track_id], set_id: state[:set_id]}

    changed? =
      Agent.get_and_update(__MODULE__, fn
        ^norm -> {false, norm}
        _current -> {true, norm}
      end)

    if changed?, do: PubSub.broadcast(Beatgrid.PubSub, @topic, {:now_playing, norm})
    norm
  end

  @doc "Clear the pointer (nothing playing) and broadcast."
  @spec clear() :: %{track_id: nil, set_id: nil}
  def clear, do: put(@empty)

  @doc """
  Reset the pointer to empty WITHOUT broadcasting — for player teardown (refresh /
  tab close), where the audio is already gone and there are no live subscribers to
  notify. Keeps a freshly-mounted page from reading a stale pointer.
  """
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> @empty end)

  @doc "Subscribe the calling process to now-playing updates."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Subscribe to cue-point marker changes (`{:markers_changed, track_id}`)."
  @spec subscribe_markers() :: :ok | {:error, term()}
  def subscribe_markers, do: PubSub.subscribe(Beatgrid.PubSub, @markers_topic)

  @doc """
  Broadcast `{:markers_changed, track_id}` so the player and that track's page reload
  the cue points. On a dedicated topic so the broader now-playing subscribers are spared.
  """
  @spec broadcast_markers_changed(term()) :: :ok
  def broadcast_markers_changed(track_id),
    do: PubSub.broadcast(Beatgrid.PubSub, @markers_topic, {:markers_changed, track_id})

  @doc "The PubSub topic now-playing updates are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic
end
