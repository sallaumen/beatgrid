defmodule Beatgrid.Sets do
  @moduledoc """
  Scored set-builder. A `RecSet` is a named, ordered chain of tracks the user
  assembles for a gig, anchored on a `target_style`. Tracks are appended from the
  scored candidates (`Mixing.rank`, excluding members), section by section
  (`fill_section/3`) or greedily (`auto_fill/2`). A finished set exports to an
  `.m3u` playlist under `<library_root>/_Sets` that Serato/VLC read directly.
  """
  import Ecto.Query

  alias Beatgrid.Library
  alias Beatgrid.Library.Marker
  alias Beatgrid.Mixing
  alias Beatgrid.Repo
  alias Beatgrid.Sets.{RecSet, RecSetQuery, SetTrack}

  @transition_types ~w(cut fade crossfade)

  @unsafe ~r/[\/\\:*?"<>|]/u

  @spec list() :: [RecSet.t()]
  defdelegate list, to: RecSetQuery

  @spec get(Ecto.UUID.t()) :: RecSet.t() | nil
  defdelegate get(id), to: RecSetQuery

  @spec tracks(RecSet.t()) :: [Library.Track.t()]
  def tracks(%RecSet{id: id}), do: RecSetQuery.ordered_tracks(id)

  @doc "The set's entries (track + section role) in order — what the screen renders."
  @spec entries(RecSet.t()) :: [
          %{track: Library.Track.t(), role: String.t() | nil, position: integer()}
        ]
  def entries(%RecSet{id: id}), do: RecSetQuery.ordered_entries(id)

  @doc "The set's opening track (position order), or nil if empty — for \"Tocar set\"."
  @spec first_track(RecSet.t() | Ecto.UUID.t()) :: Library.Track.t() | nil
  def first_track(%RecSet{id: id}), do: first_track(id)

  def first_track(set_id) when is_binary(set_id),
    do: set_id |> RecSetQuery.ordered_tracks() |> List.first()

  @doc """
  The track right after `current_track_id` in the set's current order, or nil if it
  is the last track or not a member. Queries the order fresh each call, so the player
  only needs to hold the pointer `(set_id, current_track_id)` — a reorder is honored
  automatically with no re-sync.
  """
  @spec next_after(RecSet.t() | Ecto.UUID.t(), Ecto.UUID.t()) :: Library.Track.t() | nil
  def next_after(%RecSet{id: id}, current_track_id), do: next_after(id, current_track_id)

  def next_after(set_id, current_track_id) when is_binary(set_id) do
    tracks = RecSetQuery.ordered_tracks(set_id)

    case Enum.find_index(tracks, &(&1.id == current_track_id)) do
      nil -> nil
      idx -> Enum.at(tracks, idx + 1)
    end
  end

  @spec create(String.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def create(name), do: %RecSet{} |> RecSet.changeset(%{name: name}) |> Repo.insert()

  @spec rename(RecSet.t(), String.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def rename(set, name), do: set |> RecSet.changeset(%{name: name}) |> Repo.update()

  @doc "Sets the set's target style (genre-folder key) — the anchor for style scoring."
  @spec set_target_style(RecSet.t(), String.t() | nil) ::
          {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def set_target_style(set, key),
    do: set |> RecSet.changeset(%{target_style: key}) |> Repo.update()

  @spec delete(RecSet.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def delete(set), do: Repo.delete(set)

  @doc """
  Appends a track to the end of the set (a no-op if it's already a member),
  optionally tagging it with a section `role` (e.g. `"pico"`).
  """
  @spec append(RecSet.t(), Library.Track.t(), String.t() | nil) ::
          {:ok, SetTrack.t()} | {:error, term()}
  def append(set, track, role \\ nil)

  def append(%RecSet{id: id}, track, role) do
    %SetTrack{}
    |> SetTrack.changeset(%{
      rec_set_id: id,
      track_id: track.id,
      position: RecSetQuery.count(id) + 1,
      role: role
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:rec_set_id, :track_id])
  end

  @doc "Removes a track from the set and re-numbers the remaining positions."
  @spec remove(RecSet.t(), Library.Track.t()) :: :ok
  def remove(%RecSet{id: id} = set, track) do
    SetTrack
    |> where([st], st.rec_set_id == ^id and st.track_id == ^track.id)
    |> Repo.delete_all()

    reindex(set)
    :ok
  end

  @doc "Moves a track one step up or down in the set (a no-op at the edges)."
  @spec move(RecSet.t(), Library.Track.t(), :up | :down) :: :ok
  def move(%RecSet{id: id}, track, direction) do
    rows = RecSetQuery.rows(id)
    idx = Enum.find_index(rows, &(&1.track_id == track.id))
    swap_idx = if idx, do: idx + step(direction)

    if idx && swap_idx in 0..(length(rows) - 1)//1 do
      swap_positions(Enum.at(rows, idx), Enum.at(rows, swap_idx))
    end

    :ok
  end

  defp step(:up), do: -1
  defp step(:down), do: 1

  defp swap_positions(a, b) do
    pa = a.position
    a |> SetTrack.changeset(%{position: b.position}) |> Repo.update()
    b |> SetTrack.changeset(%{position: pa}) |> Repo.update()
  end

  # ── Connections (transition INTO an entry, from the previous track) ──────────

  @doc """
  Suggests a transition for mixing `prev` into `this`: a `crossfade` (beat-aware)
  when both have outro/intro markers and effective BPMs within ~8%, a `fade` when
  the markers exist but tempos diverge, else a `cut`. `from_ms`/`to_ms` default to
  the outro(prev)/intro(this) markers (to_ms 0 when no intro).
  """
  @spec suggest_transition(Library.Track.t(), Library.Track.t()) :: map()
  def suggest_transition(prev, this) do
    out = Marker.outro(prev)
    intro = Marker.intro(this)
    bpm_prev = Library.effective(prev).bpm
    bpm_this = Library.effective(this).bpm

    type =
      cond do
        is_nil(out) or is_nil(intro) -> "cut"
        bpm_close?(bpm_prev, bpm_this) -> "crossfade"
        true -> "fade"
      end

    %{
      "enabled" => true,
      "type" => type,
      "from_ms" => out && out["ms"],
      "to_ms" => (intro && intro["ms"]) || 0
    }
  end

  defp bpm_close?(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0,
    do: abs(a - b) / max(a, b) <= 0.08

  defp bpm_close?(_a, _b), do: false

  @doc "Suggested transitions for every consecutive pair: `[{receiving_track_id, transition}]`."
  @spec suggest_all(RecSet.t()) :: [{Ecto.UUID.t(), map()}]
  def suggest_all(%RecSet{} = set) do
    set
    |> tracks()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, this] -> {this.id, suggest_transition(prev, this)} end)
  end

  @doc "Sets the incoming transition on the entry that receives it (the later track)."
  @spec connect(RecSet.t(), Library.Track.t(), map()) ::
          {:ok, SetTrack.t()} | {:error, Ecto.Changeset.t()}
  def connect(%RecSet{id: set_id}, %{id: track_id}, attrs) do
    Repo.get_by!(SetTrack, rec_set_id: set_id, track_id: track_id)
    |> SetTrack.changeset(%{transition: normalize_transition(attrs)})
    |> Repo.update()
  end

  @doc "Clears the incoming transition on an entry (back to plain sequential play)."
  @spec disconnect(RecSet.t(), Library.Track.t()) ::
          {:ok, SetTrack.t()} | {:error, Ecto.Changeset.t()}
  def disconnect(%RecSet{id: set_id}, %{id: track_id}) do
    Repo.get_by!(SetTrack, rec_set_id: set_id, track_id: track_id)
    |> SetTrack.changeset(%{transition: nil})
    |> Repo.update()
  end

  @doc "Auto-connects every consecutive pair (suggest + persist); returns `{:ok, count}`."
  @spec connect_all(RecSet.t()) :: {:ok, non_neg_integer()}
  def connect_all(%RecSet{} = set) do
    count =
      set
      |> tracks()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [prev, this] ->
        {:ok, _} = connect(set, this, suggest_transition(prev, this))
        true
      end)

    {:ok, count}
  end

  defp normalize_transition(attrs) do
    type = attrs["type"] || attrs[:type]

    %{
      "enabled" => (attrs["enabled"] || attrs[:enabled]) != false,
      "type" => if(type in @transition_types, do: type, else: "crossfade"),
      "from_ms" => attrs["from_ms"] || attrs[:from_ms],
      "to_ms" => attrs["to_ms"] || attrs[:to_ms] || 0
    }
  end

  @doc """
  Ranked candidates to append next: scored from the last track (or as an opening
  when the set is empty), anchored on the set's `target_style` and an optional
  `:target_intensity` (the active section's energy target). Excludes members.
  """
  @spec next_candidates(RecSet.t(), keyword()) :: [Mixing.suggestion()]
  def next_candidates(%RecSet{} = set, opts \\ []) do
    Mixing.rank(rank_opts(set, opts))
  end

  @doc """
  Opening candidates for an empty set: ranked by style + an opening-strength
  intensity + rating (no previous track, so no harmony/BPM).
  """
  @spec suggest_opening(RecSet.t(), keyword()) :: [Mixing.suggestion()]
  def suggest_opening(%RecSet{} = set, opts \\ []) do
    Mixing.rank(
      prev: nil,
      target_style: set.target_style,
      target_intensity:
        Keyword.get(opts, :target_intensity) || Mixing.target_intensity("abertura"),
      exclude: member_ids(set),
      limit: Keyword.get(opts, :limit, 10)
    )
  end

  @doc "Greedily appends up to `:count` (default 8) compatible tracks (style + harmony)."
  @spec auto_fill(RecSet.t(), keyword()) :: {:ok, RecSet.t()}
  def auto_fill(set, opts \\ []),
    do: {:ok, greedy_fill(set, Keyword.get(opts, :count, 8), nil, nil)}

  @doc """
  Fills a section: appends `count` tracks targeting the section role's energy,
  chained from the last track and anchored on the set's style. Each appended track
  is tagged with `role`. Stops early if no candidate remains.
  """
  @spec fill_section(RecSet.t(), String.t(), pos_integer()) :: {:ok, RecSet.t()}
  def fill_section(%RecSet{} = set, role, count) when is_integer(count) and count > 0,
    do: {:ok, greedy_fill(set, count, role, Mixing.target_intensity(role))}

  defp greedy_fill(set, count, _role, _ti) when count <= 0, do: set

  defp greedy_fill(set, count, role, ti) do
    case Mixing.rank(rank_opts(set, target_intensity: ti, limit: 1)) do
      [%{track: next} | _] ->
        append(set, next, role)
        greedy_fill(set, count - 1, role, ti)

      [] ->
        set
    end
  end

  # Console opts forwarded as-is to Mixing.rank/1 (weights + hard filters).
  @passthrough [
    :weights,
    :harmonic_only,
    :bpm_min,
    :bpm_max,
    :min_rating,
    :exclude_styles,
    :limit
  ]

  # Common rank options: anchor on the set's style, chain from the last member,
  # and exclude everything already in the set. Console weights/filters
  # (`@passthrough`) flow through unchanged.
  defp rank_opts(%RecSet{} = set, opts) do
    members = RecSetQuery.ordered_tracks(set.id)

    base = [
      target_style: set.target_style,
      target_intensity: Keyword.get(opts, :target_intensity),
      exclude: Enum.map(members, & &1.id),
      limit: Keyword.get(opts, :limit, 10)
    ]

    base =
      case List.last(members) do
        nil -> base
        last -> [{:prev, last} | base]
      end

    Keyword.merge(base, Keyword.take(opts, @passthrough))
  end

  defp member_ids(%RecSet{id: id}), do: RecSetQuery.ordered_tracks(id) |> Enum.map(& &1.id)

  @doc "Writes the set as an `.m3u` playlist under `<library_root>/_Sets`."
  @spec export_m3u(RecSet.t()) :: {:ok, Path.t()} | {:error, term()}
  def export_m3u(%RecSet{id: id, name: name}) do
    dir = Path.join(Library.library_root(), "_Sets")
    path = Path.join(dir, sanitize(name) <> ".m3u")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, m3u_body(RecSetQuery.ordered_tracks(id))) do
      {:ok, path}
    end
  end

  # --- internals ---

  defp reindex(%RecSet{id: id}) do
    id
    |> RecSetQuery.rows()
    |> Enum.with_index(1)
    |> Enum.each(fn {row, position} ->
      row |> SetTrack.changeset(%{position: position}) |> Repo.update()
    end)
  end

  defp m3u_body(tracks) do
    root = Library.library_root()
    lines = Enum.flat_map(tracks, &extinf(&1, root))
    Enum.join(["#EXTM3U" | lines], "\n") <> "\n"
  end

  defp extinf(track, root) do
    secs = if track.duration_ms, do: div(track.duration_ms, 1000), else: -1
    artist = track.tag_artist || "—"
    title = track.tag_title || track.filename
    ["#EXTINF:#{secs},#{artist} - #{title}", Path.join(root, track.rel_path)]
  end

  defp sanitize(name), do: (name || "set") |> String.replace(@unsafe, "-") |> String.trim()
end
