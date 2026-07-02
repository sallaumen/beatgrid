defmodule Beatgrid.Library.TrackQuery do
  @moduledoc "All reads for `Beatgrid.Library.Track`."

  import Ecto.Query

  alias Beatgrid.Library.{Normalize, Track}
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
          | {:sc_attempted, boolean()}
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
  All distinct, non-blank tags across PRESENT tracks, sorted — for autocomplete +
  filters. Scoped to `:present` so a tag that only survives on a quarantined/missing
  track never shows up as a filter chip that matches zero visible rows.
  """
  @spec all_tags() :: [String.t()]
  def all_tags do
    Track
    |> where([t], t.status == :present)
    |> select([t], fragment("unnest(?)", t.tags))
    |> distinct(true)
    |> Repo.all()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.sort()
  end

  @doc """
  Library browse query: present tracks with the song preloaded, filtered by a map
  of optional filters and sorted by an optional `:sort` `{field, dir}`. Paginated
  with optional `:limit` + `:offset` (the Biblioteca loads 100 at a time and
  appends on scroll).

  Filters: `genre_folder`, `rating_min`, `rating_max`, `confidence`, `tag`,
  `bpm_min`/`bpm_max` and `energy_min`/`energy_max` (both ranges over the effective
  value — Soundcharts, falling back to detected for bpm; energy is Soundcharts-only
  and the UI sends 0–100), `camelot` (+ `camelot_compatible` to widen to the
  harmonic neighbors), `unclassified` (no genre folder), `search`. Used by the
  Biblioteca screen.
  """
  @spec library(map()) :: [Track.t()]
  def library(filters \\ %{}) do
    filters
    |> library_base()
    |> sorted(filters)
    |> paginate(filters)
    |> preload([song: s], soundcharts_song: s)
    |> Repo.all()
  end

  @doc "Total present tracks matching the same filters (ignores limit/offset) — for the header count + has-more."
  @spec count_library(map()) :: non_neg_integer()
  def count_library(filters \\ %{}) do
    filters |> library_base() |> Repo.aggregate(:count, :id)
  end

  @doc "Every present track id matching the filters (ignores limit/offset) — powers \"Marcar todas\" across pages."
  @spec library_ids(map()) :: [Ecto.UUID.t()]
  def library_ids(filters \\ %{}) do
    filters |> library_base() |> select([t], t.id) |> Repo.all()
  end

  # The shared filtered base (join + WHERE chain), without sort/pagination/preload —
  # so list, count, and ids all share one filter definition.
  defp library_base(filters) do
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
    |> gold_filter(filters)
    |> filter(:unclassified, filters)
    |> filter(:search, filters)
  end

  defp paginate(query, filters) do
    case filters[:limit] do
      limit when is_integer(limit) -> query |> limit(^limit) |> offset(^(filters[:offset] || 0))
      _ -> query
    end
  end

  defp filter(query, key, filters) do
    case Map.get(filters, key) || Map.get(filters, to_string(key)) do
      nil -> query
      "" -> query
      value -> apply_filter(query, key, value)
    end
  end

  defp apply_filter(q, :genre_folder, v), do: where(q, [t], t.genre_folder == ^v)

  defp apply_filter(q, :rating_min, v) do
    case to_int(v) do
      nil -> q
      n -> where(q, [t], t.rating >= ^n)
    end
  end

  defp apply_filter(q, :rating_max, v) do
    case to_int(v) do
      nil -> q
      n -> where(q, [t], t.rating <= ^n)
    end
  end

  defp apply_filter(q, :confidence, v), do: where(q, [t], t.sc_match_confidence == ^to_atom(v))
  defp apply_filter(q, :tag, v), do: where(q, [t], fragment("? = ANY(?)", ^v, t.tags))

  defp apply_filter(q, :bpm_min, v) do
    case to_num(v) do
      nil -> q
      n -> where(q, ^dynamic(^effective_bpm() >= ^n))
    end
  end

  defp apply_filter(q, :bpm_max, v) do
    case to_num(v) do
      nil -> q
      n -> where(q, ^dynamic(^effective_bpm() <= ^n))
    end
  end

  defp apply_filter(q, :energy_min, v) do
    case to_num(v) do
      nil -> q
      n -> where(q, [song: s], s.energy >= ^(n / 100))
    end
  end

  defp apply_filter(q, :energy_max, v) do
    case to_num(v) do
      nil -> q
      n -> where(q, [song: s], s.energy <= ^(n / 100))
    end
  end

  defp apply_filter(q, :unclassified, _v), do: where(q, [t], is_nil(t.genre_folder))

  defp apply_filter(q, :search, v) do
    # A UUID matches the track by id directly (a reliable fallback when name search
    # fails). Otherwise normalize the query the same way `norm_*` are stored
    # (accent-stripped + downcased) so "Marinês"/"Gogó" match "marines"/"gogo".
    case Ecto.UUID.cast(String.trim(v)) do
      {:ok, id} ->
        where(q, [t], t.id == ^id)

      :error ->
        like = "%#{Normalize.normalize(v)}%"
        where(q, [t], ilike(t.norm_artist, ^like) or ilike(t.norm_title, ^like))
    end
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

        where(q, ^dynamic(^effective_camelot() in ^codes))
    end
  end

  # Effective values: manual override → Soundcharts → locally detected. Shared by
  # the range filters and the BPM sort so the three never drift apart.
  defp effective_bpm do
    dynamic(
      [t, song: s],
      fragment("coalesce(?, ?, ?)", t.bpm_manual, s.tempo_bpm, t.bpm_detected)
    )
  end

  defp effective_camelot do
    dynamic(
      [t, song: s],
      fragment("coalesce(?, ?, ?)", t.camelot_manual, s.camelot, t.camelot_detected)
    )
  end

  # Selo Ouro = manual true OU (sem override manual E (eixo raro setado OU views >= limiar)),
  # sempre excluindo manual=false. Espelha Beatgrid.Gold.effective/1 — inclusive lendo o
  # limiar em RUNTIME, para que os dois nunca divirjam se a config mudar sem recompilar.
  defp gold_filter(q, filters) do
    if truthy(filters[:gold] || filters["gold"]) do
      threshold = Beatgrid.Gold.view_threshold()

      where(
        q,
        [t],
        t.gold_manual == true or
          (is_nil(t.gold_manual) and
             (not is_nil(t.gold_status) or t.youtube_views >= ^threshold))
      )
    else
      q
    end
  end

  @doc """
  Faixas vindas do YouTube (`source_playlist == "youtube"`), preload da song, com
  filtros rápidos (`:unfiled`, `:unresolved`, `:gold`) e ordenação
  (`:recent` default, `:views`, `:published`). Usada pela tela /importados.
  """
  @spec youtube_imports(map()) :: [Track.t()]
  def youtube_imports(filters \\ %{}) do
    Track
    |> join(:left, [t], s in assoc(t, :soundcharts_song), as: :song)
    |> where([t], t.status == :present and t.source_playlist == "youtube")
    |> imports_filter(:unfiled, filters)
    |> imports_filter(:unresolved, filters)
    |> gold_filter(filters)
    |> imports_sort(filters)
    |> preload([song: s], soundcharts_song: s)
    |> Repo.all()
  end

  defp imports_filter(q, :unfiled, filters) do
    if truthy(filters[:unfiled] || filters["unfiled"]),
      do: where(q, [t], is_nil(t.genre_folder)),
      else: q
  end

  defp imports_filter(q, :unresolved, filters) do
    if truthy(filters[:unresolved] || filters["unresolved"]),
      do: where(q, [t], is_nil(t.soundcharts_song_id)),
      else: q
  end

  defp imports_sort(q, filters) do
    case filters[:sort] || filters["sort"] do
      :views -> order_by(q, [t], desc_nulls_last: t.youtube_views)
      "views" -> order_by(q, [t], desc_nulls_last: t.youtube_views)
      :published -> order_by(q, [t], desc_nulls_last: t.youtube_published_at)
      "published" -> order_by(q, [t], desc_nulls_last: t.youtube_published_at)
      _ -> order_by(q, [t], desc: t.inserted_at)
    end
  end

  defp truthy(v), do: v in [true, "true", "on", "1"]

  @doc "Present tracks by the same normalized artist (excluding `except_id`), song preloaded."
  @spec present_by_artist(String.t(), Ecto.UUID.t()) :: [Track.t()]
  def present_by_artist(norm_artist, except_id) do
    Track
    |> where([t], t.status == :present and t.norm_artist == ^norm_artist)
    |> where([t], t.id != ^except_id)
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  @doc "Present tracks whose normalized title contains `fragment` (excluding `except_id`), song preloaded."
  @spec present_by_title_fragment(String.t(), Ecto.UUID.t()) :: [Track.t()]
  def present_by_title_fragment(fragment, except_id) do
    like = "%#{fragment}%"

    Track
    |> where([t], t.status == :present and t.id != ^except_id)
    |> where([t], ilike(t.norm_title, ^like))
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  @doc "Every track already linked to a Soundcharts song, song preloaded — the backfill input."
  @spec resolved_with_song() :: [Track.t()]
  def resolved_with_song do
    Track
    |> where([t], not is_nil(t.soundcharts_song_id))
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  @doc """
  Candidates for the set scorer: present, not in `exclude`, carrying at least one
  mixing signal (Soundcharts match, detected key or detected BPM), optionally gated
  by `:min_rating` / `:exclude_styles`, with the song preloaded.
  """
  @spec mixing_candidates([Ecto.UUID.t()], keyword()) :: [Track.t()]
  def mixing_candidates(exclude, opts \\ []) do
    Track
    |> where([t], t.status == :present)
    |> where([t], t.id not in ^exclude)
    |> where(
      [t],
      not is_nil(t.soundcharts_song_id) or not is_nil(t.camelot_detected) or
        not is_nil(t.bpm_detected)
    )
    |> min_rating(opts[:min_rating])
    |> exclude_styles(opts[:exclude_styles])
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  defp min_rating(q, n) when is_integer(n), do: where(q, [t], t.rating >= ^n)
  defp min_rating(q, _), do: q

  defp exclude_styles(q, [_ | _] = keys), do: where(q, [t], t.genre_folder not in ^keys)
  defp exclude_styles(q, _), do: q

  @doc "The oldest present track exactly matching a normalized artist + title pair."
  @spec present_by_normalized_pair(String.t(), String.t()) :: Track.t() | nil
  def present_by_normalized_pair(norm_artist, norm_title) do
    Track
    |> where([t], t.status == :present)
    |> where([t], t.norm_artist == ^norm_artist and t.norm_title == ^norm_title)
    |> order_by([t], asc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Most recently analyzed present track of a genre folder — the example-set seed."
  @spec latest_analyzed_present(String.t()) :: Track.t() | nil
  def latest_analyzed_present(genre_folder) do
    Track
    |> where([t], t.status == :present and t.genre_folder == ^genre_folder)
    |> order_by([t], desc_nulls_last: t.analyzed_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Average duration (ms) of present tracks outside `excluded_styles` — set-length planning."
  @spec avg_present_duration_ms([String.t()]) :: number() | Decimal.t() | nil
  def avg_present_duration_ms(excluded_styles) do
    Track
    |> where([t], t.status == :present)
    |> where([t], not is_nil(t.duration_ms) and t.duration_ms > 0)
    |> exclude_styles(excluded_styles)
    |> select([t], avg(t.duration_ms))
    |> Repo.one()
  end

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

  defp order_terms(:bpm, d), do: [{nulls(d), effective_bpm()}]

  # Sort the "Tom" column by the Camelot wheel, not lexically (else "10A" sorts
  # before "2A"). Order by the numeric part (1–12) extracted in SQL, then the A/B
  # letter ("A" < "B"). A nil/malformed code yields a nil number → nulls-last.
  defp order_terms(:key, d),
    do: [
      {nulls(d),
       dynamic(
         [t, song: s],
         fragment(
           "(substring(coalesce(?, ?, ?) from '^[0-9]+'))::integer",
           t.camelot_manual,
           s.camelot,
           t.camelot_detected
         )
       )},
      {nulls(d),
       dynamic(
         [t, song: s],
         fragment(
           "upper(right(coalesce(?, ?, ?), 1))",
           t.camelot_manual,
           s.camelot,
           t.camelot_detected
         )
       )}
    ]

  defp order_terms(_other, d), do: order_terms(:artist, d)

  defp nulls(:asc), do: :asc_nulls_last
  defp nulls(:desc), do: :desc_nulls_last

  # Parse user-supplied filter inputs defensively — a `type=number` field can still
  # post "12.5", ".", or "" and must not crash the LiveView. nil means "skip filter".
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_num(v) when is_number(v), do: v

  defp to_num(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

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

  defp reduce_opt({:sc_attempted, true}, q),
    do: where(q, [t], not is_nil(t.sc_attempted_at))

  defp reduce_opt({:sc_attempted, false}, q),
    do: where(q, [t], is_nil(t.sc_attempted_at))

  defp reduce_opt({:order_by, order}, q), do: order_by(q, ^order)

  defp reduce_opt({opt, value}, _q),
    do: raise(Beatgrid.Query.FilterError, field: opt, value: value)
end
