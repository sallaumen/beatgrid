defmodule Beatgrid.Mixing do
  @moduledoc """
  Harmonic mixing suggestions. `suggest_next/2` ranks the tracks that mix well
  out of a given track by Camelot compatibility, then BPM closeness, then energy
  delta. Pure ranking over the library — no AI, no quota. Each track's effective
  Camelot/BPM is its Soundcharts value, falling back to the locally-detected one
  (`Beatgrid.Analysis`), so tracks without a Soundcharts match still participate.
  """
  import Ecto.Query

  alias Beatgrid.Library.Track
  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.{Camelot, Song}

  @default_limit 10
  @default_bpm_tolerance 0.08

  @type suggestion :: %{
          track: Track.t(),
          song: Song.t() | nil,
          camelot: String.t(),
          bpm: float(),
          tier: pos_integer(),
          score: float()
        }

  @doc """
  Ranked harmonically-compatible next tracks for `track`. Options: `:limit`
  (default 10), `:bpm_tolerance` (fraction, default 0.08 = ±8%) and `:exclude`
  (track ids to skip). Returns `[]` if the track has no Camelot/BPM (neither
  Soundcharts nor detected).
  """
  @spec suggest_next(Track.t(), keyword()) :: [suggestion()]
  def suggest_next(%Track{} = track, opts \\ []) do
    track = Repo.preload(track, :soundcharts_song)
    rank(track, effective(track), opts)
  end

  # Effective Camelot/BPM/energy: Soundcharts value, falling back to detected.
  defp effective(track) do
    song = track.soundcharts_song

    %{
      camelot: (song && song.camelot) || track.camelot_detected,
      bpm: (song && song.tempo_bpm) || track.bpm_detected,
      energy: song && song.energy
    }
  end

  defp rank(track, %{camelot: camelot, bpm: bpm, energy: energy}, opts)
       when is_binary(camelot) and is_number(bpm) do
    limit = Keyword.get(opts, :limit, @default_limit)
    tolerance = Keyword.get(opts, :bpm_tolerance, @default_bpm_tolerance)
    exclude = Keyword.get(opts, :exclude, [])
    neighbors = Camelot.neighbors(camelot)
    max_delta = bpm * tolerance

    [track.id | exclude]
    |> candidates()
    |> Enum.map(&{&1, effective(&1)})
    |> Enum.filter(fn {_track, e} -> compatible?(e, neighbors, bpm, max_delta) end)
    |> Enum.map(fn {track, e} -> score(track, e, camelot, bpm, energy, max_delta) end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp rank(_track, _effective, _opts), do: []

  defp candidates(exclude_ids) do
    Track
    |> where([t], t.id not in ^exclude_ids)
    |> where([t], not is_nil(t.soundcharts_song_id) or not is_nil(t.camelot_detected))
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  defp compatible?(%{camelot: cam, bpm: bpm}, neighbors, ref_bpm, max_delta)
       when is_binary(cam) and is_number(bpm) do
    cam in neighbors and abs(bpm - ref_bpm) <= max_delta
  end

  defp compatible?(_effective, _neighbors, _ref_bpm, _max_delta), do: false

  defp score(
         track,
         %{camelot: cam, bpm: bpm, energy: energy},
         ref_camelot,
         ref_bpm,
         ref_energy,
         max_delta
       ) do
    tier = tier(ref_camelot, cam)
    bpm_closeness = 1.0 - abs(bpm - ref_bpm) / max_delta

    %{
      track: track,
      song: track.soundcharts_song,
      camelot: cam,
      bpm: bpm,
      tier: tier,
      score: tier * 100 + bpm_closeness * 10 + energy_closeness(ref_energy, energy)
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
