defmodule Beatgrid.Playback.NowPlaying do
  @moduledoc """
  The app-wide "now playing" pointer: which track (and, if any, which set) is loaded
  in the global player. The owning player is monitored so every
  LiveView can read it **on mount** (`get/0`) and stay in sync via a PubSub broadcast
  (`subscribe/0`). Holds only `%{track_id, set_id}` — the *pointer*, never a track
  list; play/pause is transient client state and intentionally not stored here.
  """
  use GenServer

  alias Phoenix.PubSub

  @topic "now_playing"
  # Cue-point marker changes go on their OWN topic so the many now-playing subscribers
  # (Library/RecSet/Review highlight rows) don't get messages they don't handle — only
  # the player and the track page subscribe here.
  @markers_topic "markers"
  @empty %{track_id: nil, set_id: nil}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Current pointer: `%{track_id, set_id}` (either may be nil)."
  @spec get() :: %{track_id: term() | nil, set_id: term() | nil}
  def get, do: GenServer.call(__MODULE__, :get)

  @doc "Claim the pointer, broadcasting only if the selected track or set changed."
  @spec put(map()) :: %{track_id: term() | nil, set_id: term() | nil}
  def put(state),
    do: GenServer.call(__MODULE__, {:put, %{track_id: state[:track_id], set_id: state[:set_id]}})

  @doc "Detach the matching set from the caller-owned pointer, keeping the selected track."
  @spec detach_set(term(), term()) :: :ok
  def detach_set(set_id, track_id),
    do: GenServer.call(__MODULE__, {:detach_set, %{set_id: set_id, track_id: track_id}})

  @doc "Clear the pointer unconditionally."
  @spec clear() :: %{track_id: nil, set_id: nil}
  def clear, do: put(@empty)

  @doc "Clear the pointer if this player still owns it."
  @spec release() :: :ok
  def release, do: GenServer.call(__MODULE__, :release)

  @doc "Unconditionally reset the pointer without broadcasting."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{pointer: @empty, owner: nil, ref: nil}}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.pointer, state}

  def handle_call({:put, pointer}, {pid, _tag}, state) do
    owner = if pointer.track_id, do: pid
    {:reply, pointer, publish(state, pointer, owner)}
  end

  def handle_call({:detach_set, pointer}, {pid, _tag}, %{owner: pid, pointer: pointer} = state),
    do: {:reply, :ok, publish(state, %{pointer | set_id: nil}, pid)}

  def handle_call({:detach_set, _pointer}, _from, state), do: {:reply, :ok, state}

  def handle_call(:release, {pid, _tag}, %{owner: pid} = state),
    do: {:reply, :ok, publish(state, @empty, nil)}

  def handle_call(:release, _from, state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state),
    do: {:reply, :ok, %{monitor_owner(state, nil) | pointer: @empty}}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state),
    do: {:noreply, publish(state, @empty, nil)}

  defp publish(state, pointer, owner) do
    if pointer != state.pointer,
      do: PubSub.broadcast(Beatgrid.PubSub, @topic, {:now_playing, pointer})

    %{monitor_owner(state, owner) | pointer: pointer}
  end

  defp monitor_owner(%{owner: owner} = state, owner), do: state

  defp monitor_owner(state, owner) do
    if state.ref, do: Process.demonitor(state.ref, [:flush])
    %{state | owner: owner, ref: owner && Process.monitor(owner)}
  end

  @doc "Subscribe the calling process to now-playing updates."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Subscribe to cue-point marker changes (`{:markers_changed, track_id}`)."
  @spec subscribe_markers() :: :ok | {:error, term()}
  def subscribe_markers, do: PubSub.subscribe(Beatgrid.PubSub, @markers_topic)

  @doc """
  Broadcast `{:markers_changed, track_id}` so the player, track page and DJ console
  can refresh cue points. Other now-playing subscribers use a separate topic.
  """
  @spec broadcast_markers_changed(term()) :: :ok
  def broadcast_markers_changed(track_id),
    do: PubSub.broadcast(Beatgrid.PubSub, @markers_topic, {:markers_changed, track_id})

  @doc "The PubSub topic now-playing updates are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic
end
