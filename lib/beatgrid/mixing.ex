defmodule Beatgrid.Mixing do
  @moduledoc """
  The set scorer. `rank/1` ranks library tracks as the *next* (or *opening*) track
  for a set, as a weighted blend of five soft criteria — **style** affinity to the
  set's target genre, harmonic **proximity** on the Camelot wheel, fit to the
  section's **intensity** target, **BPM** smoothness, and the user's **rating**.

  Everything is a soft score, not a filter: there's always a ranking, even with no
  perfect harmonic neighbor — incompatible options just sink. The weights, the
  energy-arc sections and the style matrix (`StyleAffinity`) live in the backend and
  are read by the UI's "Critérios" modal, so the screen always mirrors the engine.

  Each track's effective Camelot/BPM/energy is its Soundcharts value, falling back
  to the locally-detected analysis (`Beatgrid.Analysis`), so tracks without a
  Soundcharts match still participate.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{Track, TrackQuery}
  alias Beatgrid.Mixing.StyleAffinity
  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.{Camelot, Song}

  @default_limit 10
  @bpm_window 16.0
  @bpm_floor 90.0
  @bpm_ceil 160.0

  @weights %{style: 40, harmony: 30, intensity: 20, bpm: 8, rating: 2}

  @sections [
    %{
      key: "abertura",
      label: "Abertura",
      target_intensity: 0.70,
      hint: "Entrada forte, com espaço pra crescer"
    },
    %{
      key: "subida",
      label: "Subida",
      target_intensity: 0.82,
      hint: "Energia subindo rumo ao pico"
    },
    %{key: "pico", label: "Pico", target_intensity: 0.95, hint: "Auge do set"},
    %{
      key: "plato",
      label: "Platô",
      target_intensity: 0.75,
      hint: "Mantém o alto, segura a pista"
    },
    %{key: "queda", label: "Queda", target_intensity: 0.45, hint: "Esfria rumo ao encerramento"}
  ]

  @type breakdown :: %{
          style: float(),
          harmony: float(),
          intensity: float(),
          bpm: float(),
          rating: float()
        }

  @type suggestion :: %{
          track: Track.t(),
          song: Song.t() | nil,
          camelot: String.t() | nil,
          bpm: float() | nil,
          intensity: float(),
          score: float(),
          breakdown: breakdown()
        }

  # ---- config (read by the UI's "Critérios" modal) ----

  @doc "Scoring weights per criterion."
  @spec weights() :: %{
          style: number(),
          harmony: number(),
          intensity: number(),
          bpm: number(),
          rating: number()
        }
  def weights, do: @weights

  @doc "Coerces a partial/dirty weights map into a full, safe map (numbers ≥ 0; missing keys use defaults)."
  @spec clamp_weights(map() | nil) :: map()
  def clamp_weights(nil), do: @weights

  def clamp_weights(w) when is_map(w) do
    Map.new(@weights, fn {k, default} -> {k, coerce_weight(Map.get(w, k, default), default)} end)
  end

  defp coerce_weight(v, _default) when is_number(v) and v >= 0, do: v

  defp coerce_weight(v, default) when is_binary(v) do
    case Float.parse(v) do
      {f, _} when f >= 0 -> f
      _ -> default
    end
  end

  defp coerce_weight(_v, default), do: default

  @doc "The energy-arc sections with their target intensity (0–1)."
  @spec sections() :: [
          %{key: String.t(), label: String.t(), target_intensity: float(), hint: String.t()}
        ]
  def sections, do: @sections

  @doc "One section by key, or nil."
  @spec section(String.t() | nil) :: map() | nil
  def section(key), do: Enum.find(@sections, &(&1.key == key))

  @doc "Target intensity for a section key, or nil if unknown."
  @spec target_intensity(String.t() | nil) :: float() | nil
  def target_intensity(key), do: with(%{target_intensity: ti} <- section(key), do: ti)

  # ---- signals ----

  @doc "Track intensity in [0,1]: Soundcharts energy, else a BPM proxy, else 0.5."
  @spec intensity(Track.t()) :: float()
  def intensity(%Track{} = track) do
    track |> Repo.preload(:soundcharts_song) |> effective() |> intensity_of()
  end

  @doc """
  Harmonic proximity of two Camelot codes in [0,1]: same key 1.0; relative/±1
  neighbor 0.8; two wheel-steps 0.4; farther 0.1; unknown 0.5 (neutral).
  """
  @spec harmony(String.t() | nil, String.t() | nil) :: float()
  def harmony(a, b) when is_nil(a) or is_nil(b), do: 0.5

  def harmony(a, b) do
    cond do
      a == b -> 1.0
      Camelot.compatible?(a, b) -> 0.8
      true -> by_distance(Camelot.wheel_distance(a, b))
    end
  end

  defp by_distance(nil), do: 0.5
  defp by_distance(2), do: 0.4
  defp by_distance(_), do: 0.1

  # ---- ranking ----

  @doc """
  Ranks candidate next tracks. Options:
    * `:prev` — the previous track (`nil` for the opening; harmony/BPM then don't apply)
    * `:target_style` — the set's genre-folder key (nil = no style preference)
    * `:target_intensity` — the current section's energy target 0–1 (nil = no preference)
    * `:exclude` — track ids to skip
    * `:limit` — max results (default 10)
  """
  @spec rank(keyword()) :: [suggestion()]
  def rank(opts \\ []) do
    opts
    |> Keyword.get(:exclude, [])
    |> candidate_pool(opts)
    |> rank_pool(Keyword.delete(opts, :exclude))
  end

  @doc """
  Ranks over an already-loaded candidate pool — the planner's per-slot path:
  it fetches the pool once per plan (`candidate_pool/2`) and re-ranks in memory,
  so the hard filters (`:bpm_min`/`:bpm_max`, styles, rating…) belong to the
  fetch and only the scoring options (+ `:exclude`, `:harmonic_only`) act here.
  """
  @spec rank_pool([Track.t()], keyword()) :: [suggestion()]
  def rank_pool(pool, opts \\ []) do
    exclude = MapSet.new(Keyword.get(opts, :exclude, []))
    limit = Keyword.get(opts, :limit, @default_limit)
    ctx = scoring_ctx(opts)

    pool
    |> Enum.reject(&MapSet.member?(exclude, &1.id))
    |> filter_harmonic(ctx.prev_eff, opts[:harmonic_only] == true)
    |> Enum.map(&score(&1, ctx))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc "Loads the SQL-filtered candidate pool (hard filters only; no scoring)."
  @spec candidate_pool([Ecto.UUID.t()], keyword()) :: [Track.t()]
  def candidate_pool(exclude, opts \\ []) do
    TrackQuery.mixing_candidates(
      exclude,
      Keyword.take(opts, [
        :bpm_min,
        :bpm_max,
        :min_rating,
        :allow_styles,
        :exclude_styles,
        :gold_only,
        :less_vocals,
        :restrict_ids,
        :escape_styles
      ])
    )
  end

  # The per-rank scoring context, built once per rank/rank_pool call.
  defp scoring_ctx(opts) do
    prev = Keyword.get(opts, :prev)

    %{
      prev_eff: prev && effective(Repo.preload(prev, :soundcharts_song)),
      target_style: Keyword.get(opts, :target_style),
      target_intensity: Keyword.get(opts, :target_intensity),
      weights: opts |> Keyword.get(:weights) |> clamp_weights(),
      tiers: Keyword.get(opts, :style_tiers, %{})
    }
  end

  defp filter_harmonic(tracks, _prev_eff, false), do: tracks

  defp filter_harmonic(tracks, prev_eff, true),
    do: Enum.filter(tracks, &harmonic_ok?(prev_eff, effective(&1).camelot))

  defp harmonic_ok?(nil, _camelot), do: true
  defp harmonic_ok?(_prev_eff, nil), do: false

  defp harmonic_ok?(%{camelot: a}, b),
    do: a == b or Camelot.compatible?(a, b)

  # ctx: the scoring context from scoring_ctx/1, built once per rank call.
  defp score(track, ctx) do
    %{
      prev_eff: prev_eff,
      target_style: target_style,
      target_intensity: target_intensity,
      weights: weights,
      tiers: tiers
    } = ctx

    e = effective(track)

    parts = %{
      # A style tier (planner's "se muito boa" scale) shrinks the style score
      # of secondary folders, so they only surface when another dimension
      # (rating, arc fit) makes them stand out. 1.0 (or no tiers) = unchanged.
      style:
        StyleAffinity.affinity(target_style, track.genre_folder) *
          Map.get(tiers, track.genre_folder, 1.0),
      harmony: if(prev_eff, do: harmony(prev_eff.camelot, e.camelot), else: 0.0),
      intensity: intensity_fit(target_intensity, intensity_of(e)),
      bpm: if(prev_eff, do: bpm_smoothness(prev_eff.bpm, e.bpm), else: 0.0),
      rating: (track.rating || 0) / 10
    }

    %{
      track: track,
      song: track.soundcharts_song,
      camelot: e.camelot,
      bpm: e.bpm,
      intensity: intensity_of(e),
      breakdown: parts,
      score:
        weights.style * parts.style + weights.harmony * parts.harmony +
          weights.intensity * parts.intensity + weights.bpm * parts.bpm +
          weights.rating * parts.rating
    }
  end

  # Effective Camelot/BPM/energy: Soundcharts value, falling back to detected.
  defp effective(track), do: Library.effective(track)

  defp intensity_of(%{energy: e}) when is_number(e), do: clamp(e)

  defp intensity_of(%{bpm: bpm}) when is_number(bpm),
    do: clamp((bpm - @bpm_floor) / (@bpm_ceil - @bpm_floor))

  defp intensity_of(_), do: 0.5

  defp intensity_fit(nil, _value), do: 0.5
  defp intensity_fit(target, value), do: max(0.0, 1.0 - abs(target - value))

  defp bpm_smoothness(a, b) when is_number(a) and is_number(b),
    do: max(0.0, 1.0 - abs(a - b) / @bpm_window)

  defp bpm_smoothness(_a, _b), do: 0.5

  defp clamp(v) when v < 0.0, do: 0.0
  defp clamp(v) when v > 1.0, do: 1.0
  defp clamp(v), do: v
end
