defmodule Beatgrid.Mixing do
  @moduledoc """
  Harmonic mixing suggestions. `suggest_next/2` ranks the tracks that mix well
  out of a given track by Camelot compatibility, then BPM closeness, then energy
  delta. Pure ranking over the resolved library — no AI, no quota.
  """
  import Ecto.Query

  alias Beatgrid.Library.Track
  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.{Camelot, Song}

  @default_limit 10
  @default_bpm_tolerance 0.08

  @type suggestion :: %{
          track: Track.t(),
          song: Song.t(),
          camelot: String.t(),
          bpm: float(),
          tier: pos_integer(),
          score: float()
        }

  @doc """
  Ranked harmonically-compatible next tracks for `track`. Options: `:limit`
  (default 10) and `:bpm_tolerance` (fraction, default 0.08 = ±8%). Returns `[]`
  if the track is not resolved or lacks a Camelot/BPM.
  """
  @spec suggest_next(Track.t(), keyword()) :: [suggestion()]
  def suggest_next(%Track{} = track, opts \\ []) do
    track = Repo.preload(track, :soundcharts_song)
    rank(track, track.soundcharts_song, opts)
  end

  defp rank(track, %Song{camelot: camelot, tempo_bpm: bpm} = song, opts)
       when is_binary(camelot) and is_number(bpm) do
    limit = Keyword.get(opts, :limit, @default_limit)
    tolerance = Keyword.get(opts, :bpm_tolerance, @default_bpm_tolerance)
    exclude = Keyword.get(opts, :exclude, [])
    neighbors = Camelot.neighbors(camelot)
    max_delta = bpm * tolerance

    [track.id | exclude]
    |> candidates()
    |> Enum.filter(&compatible?(&1.soundcharts_song, neighbors, bpm, max_delta))
    |> Enum.map(&score(&1, camelot, bpm, song.energy, max_delta))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp rank(_track, _song, _opts), do: []

  defp candidates(exclude_ids) do
    Track
    |> where([t], not is_nil(t.soundcharts_song_id) and t.id not in ^exclude_ids)
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  defp compatible?(%Song{camelot: cam, tempo_bpm: bpm}, neighbors, ref_bpm, max_delta)
       when is_binary(cam) and is_number(bpm) do
    cam in neighbors and abs(bpm - ref_bpm) <= max_delta
  end

  defp compatible?(_song, _neighbors, _ref_bpm, _max_delta), do: false

  defp score(track, ref_camelot, ref_bpm, ref_energy, max_delta) do
    song = track.soundcharts_song
    tier = tier(ref_camelot, song.camelot)
    bpm_closeness = 1.0 - abs(song.tempo_bpm - ref_bpm) / max_delta
    energy_closeness = energy_closeness(ref_energy, song.energy)

    %{
      track: track,
      song: song,
      camelot: song.camelot,
      bpm: song.tempo_bpm,
      tier: tier,
      score: tier * 100 + bpm_closeness * 10 + energy_closeness
    }
  end

  # same key (3) > relative major/minor (2) > ±1 neighbor (1)
  defp tier(reference, candidate) do
    {ref_n, ref_l} = split(reference)
    {cand_n, cand_l} = split(candidate)

    cond do
      candidate == reference -> 3
      cand_n == ref_n and cand_l != ref_l -> 2
      true -> 1
    end
  end

  defp split(code), do: {String.slice(code, 0, String.length(code) - 1), String.last(code)}

  defp energy_closeness(a, b) when is_number(a) and is_number(b), do: 1.0 - abs(a - b)
  defp energy_closeness(_a, _b), do: 0.5
end
