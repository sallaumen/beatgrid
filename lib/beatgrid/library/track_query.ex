defmodule Beatgrid.Library.TrackQuery do
  @moduledoc "All reads for `Beatgrid.Library.Track`."

  import Ecto.Query

  alias Beatgrid.Library.Track
  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.Camelot

  @type list_opt ::
          {:ids, [Ecto.UUID.t()]}
          | {:status, atom()}
          | {:genre_folder, String.t() | nil}
          | {:with_quality_issues, boolean()}
          | {:resolved, boolean()}
          | {:analyzed, boolean()}
          | {:loudness, boolean()}
          | {:loudness_attempted, boolean()}
          | {:order_by, term()}

  @spec list_by([list_opt()]) :: [Track.t()]
  def list_by(opts \\ []) do
    opts
    |> Keyword.put_new(:order_by, asc: :rel_path)
    |> Enum.reduce(Track, &reduce_opt/2)
    |> Repo.all()
  end

  @spec get(Ecto.UUID.t()) :: Track.t() | nil
  def get(id), do: Repo.get(Track, id)

  @spec get_with_song(Ecto.UUID.t()) :: Track.t() | nil
  def get_with_song(id) do
    case Repo.get(Track, id) do
      nil -> nil
      track -> Repo.preload(track, :soundcharts_song)
    end
  end

  @spec get_by_path(String.t()) :: Track.t() | nil
  def get_by_path(rel_path), do: Repo.get_by(Track, rel_path: rel_path)

  @doc """
  Library browse query: present tracks with the song preloaded, filtered by a map
  of optional filters and sorted by an optional `:sort` `{field, dir}`.

  Filters: `genre_folder`, `rating_min`, `rating_max`, `confidence`, `tag`,
  `bpm_min`/`bpm_max` and `energy_min`/`energy_max` (both ranges over the effective
  value — Soundcharts, falling back to detected for bpm; energy is Soundcharts-only
  and the UI sends 0–100), `camelot` (+ `camelot_compatible` to widen to the
  harmonic neighbors), `unclassified` (no genre folder), `search`. Used by the
  Biblioteca screen.
  """
  @spec library(map()) :: [Track.t()]
  def library(filters \\ %{}) do
    Track
    |> join(:left, [t], s in assoc(t, :soundcharts_song), as: :song)
    |> where([t], t.status == :present)
    |> filter(:genre_folder, filters)
    |> filter(:rating_min, filters)
    |> filter(:rating_max, filters)
    |> filter(:confidence, filters)
    |> filter(:tag, filters)
    |> filter(:bpm_min, filters)
    |> filter(:bpm_max, filters)
    |> filter(:energy_min, filters)
    |> filter(:energy_max, filters)
    |> camelot_filter(filters)
    |> filter(:unclassified, filters)
    |> filter(:search, filters)
    |> sorted(filters)
    |> preload([song: s], soundcharts_song: s)
    |> Repo.all()
  end

  defp filter(query, key, filters) do
    case Map.get(filters, key) || Map.get(filters, to_string(key)) do
      nil -> query
      "" -> query
      value -> apply_filter(query, key, value)
    end
  end

  defp apply_filter(q, :genre_folder, v), do: where(q, [t], t.genre_folder == ^v)
  defp apply_filter(q, :rating_min, v), do: where(q, [t], t.rating >= ^to_int(v))
  defp apply_filter(q, :rating_max, v), do: where(q, [t], t.rating <= ^to_int(v))
  defp apply_filter(q, :confidence, v), do: where(q, [t], t.sc_match_confidence == ^to_atom(v))
  defp apply_filter(q, :tag, v), do: where(q, [t], fragment("? = ANY(?)", ^v, t.tags))

  defp apply_filter(q, :bpm_min, v),
    do:
      where(
        q,
        [t, song: s],
        fragment("coalesce(?, ?, ?)", t.bpm_manual, s.tempo_bpm, t.bpm_detected) >= ^to_num(v)
      )

  defp apply_filter(q, :bpm_max, v),
    do:
      where(
        q,
        [t, song: s],
        fragment("coalesce(?, ?, ?)", t.bpm_manual, s.tempo_bpm, t.bpm_detected) <= ^to_num(v)
      )

  defp apply_filter(q, :energy_min, v), do: where(q, [song: s], s.energy >= ^(to_num(v) / 100))
  defp apply_filter(q, :energy_max, v), do: where(q, [song: s], s.energy <= ^(to_num(v) / 100))

  defp apply_filter(q, :unclassified, _v), do: where(q, [t], is_nil(t.genre_folder))

  defp apply_filter(q, :search, v) do
    like = "%#{v}%"
    where(q, [t], ilike(t.norm_artist, ^like) or ilike(t.norm_title, ^like))
  end

  # Camelot needs BOTH keys (`:camelot` + `:camelot_compatible`), so it gets a
  # dedicated step rather than the generic single-key `filter/2`.
  defp camelot_filter(q, filters) do
    case filters[:camelot] || filters["camelot"] do
      nil ->
        q

      "" ->
        q

      code ->
        codes =
          if truthy(filters[:camelot_compatible] || filters["camelot_compatible"]),
            do: Camelot.neighbors(code),
            else: [code]

        where(
          q,
          [t, song: s],
          fragment("coalesce(?, ?, ?)", t.camelot_manual, s.camelot, t.camelot_detected) in ^codes
        )
    end
  end

  defp truthy(v), do: v in [true, "true", "on", "1"]

  defp sorted(q, filters) do
    case filters[:sort] || filters["sort"] do
      {field, dir} -> order_by(q, ^order_terms(field, dir))
      _ -> order_by(q, [t], asc: t.norm_artist, asc: t.norm_title)
    end
  end

  defp order_terms(:artist, d),
    do: [{d, dynamic([t], t.norm_artist)}, {d, dynamic([t], t.norm_title)}]

  defp order_terms(:folder, d), do: [{nulls(d), dynamic([t], t.genre_folder)}]
  defp order_terms(:rating, d), do: [{nulls(d), dynamic([t], t.rating)}]
  defp order_terms(:confidence, d), do: [{nulls(d), dynamic([t], t.sc_match_confidence)}]
  defp order_terms(:energy, d), do: [{nulls(d), dynamic([_t, song: s], s.energy)}]
  # The "Vol." column DISPLAYS the suggested gain (≈ target − LUFS), which is inverse
  # to LUFS — so ascending gain = descending LUFS. Flip the direction so the visible
  # numbers sort the way the arrow implies; nulls (unmeasured) always last.
  defp order_terms(:loudness, :asc), do: [{nulls(:desc), dynamic([t], t.loudness_lufs)}]
  defp order_terms(:loudness, :desc), do: [{nulls(:asc), dynamic([t], t.loudness_lufs)}]

  defp order_terms(:bpm, d),
    do: [
      {nulls(d),
       dynamic(
         [t, song: s],
         fragment("coalesce(?, ?, ?)", t.bpm_manual, s.tempo_bpm, t.bpm_detected)
       )}
    ]

  defp order_terms(:key, d),
    do: [
      {nulls(d),
       dynamic(
         [t, song: s],
         fragment("coalesce(?, ?, ?)", t.camelot_manual, s.camelot, t.camelot_detected)
       )}
    ]

  defp order_terms(_other, d), do: order_terms(:artist, d)

  defp nulls(:asc), do: :asc_nulls_last
  defp nulls(:desc), do: :desc_nulls_last

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_num(v) when is_number(v), do: v
  defp to_num(v) when is_binary(v), do: String.to_integer(v)
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_existing_atom(v)

  @spec count([list_opt()]) :: non_neg_integer()
  def count(opts \\ []) do
    opts
    |> Enum.reduce(Track, &reduce_opt/2)
    |> Repo.aggregate(:count, :id)
  end

  defp reduce_opt({:ids, ids}, q), do: where(q, [t], t.id in ^ids)
  defp reduce_opt({:status, status}, q), do: where(q, [t], t.status == ^status)
  defp reduce_opt({:genre_folder, nil}, q), do: where(q, [t], is_nil(t.genre_folder))
  defp reduce_opt({:genre_folder, folder}, q), do: where(q, [t], t.genre_folder == ^folder)
  defp reduce_opt({:with_quality_issues, true}, q), do: where(q, [t], t.quality_issues != ^[])
  defp reduce_opt({:with_quality_issues, false}, q), do: where(q, [t], t.quality_issues == ^[])
  defp reduce_opt({:resolved, true}, q), do: where(q, [t], not is_nil(t.soundcharts_song_id))
  defp reduce_opt({:resolved, false}, q), do: where(q, [t], is_nil(t.soundcharts_song_id))
  defp reduce_opt({:analyzed, true}, q), do: where(q, [t], not is_nil(t.analyzed_at))
  defp reduce_opt({:analyzed, false}, q), do: where(q, [t], is_nil(t.analyzed_at))
  defp reduce_opt({:loudness, true}, q), do: where(q, [t], not is_nil(t.loudness_lufs))
  defp reduce_opt({:loudness, false}, q), do: where(q, [t], is_nil(t.loudness_lufs))

  defp reduce_opt({:loudness_attempted, true}, q),
    do: where(q, [t], not is_nil(t.loudness_attempted_at))

  defp reduce_opt({:loudness_attempted, false}, q),
    do: where(q, [t], is_nil(t.loudness_attempted_at))

  defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)
end
