defmodule Beatgrid.Repertoire.RecommendationAI do
  @moduledoc """
  AI curation/recommendation: artists/songs a genre folder is likely MISSING
  (`suggest_gaps/2`), songs that pair well with a given track (`suggest_matches/2`),
  and a classification rubric for a folder (`suggest_description/2`). Pure analysis —
  no disk, no Soundcharts quota.
  """
  import Ecto.Query

  alias Beatgrid.AI
  alias Beatgrid.AI.Schema
  alias Beatgrid.Library.{GenreFolders, Track}
  alias Beatgrid.Repo

  defmodule Description do
    @moduledoc "An AI-suggested classification rubric for a genre folder."
    @type t :: %__MODULE__{}
    defstruct [:description, :rationale]
  end

  defmodule Gap do
    @moduledoc "A suggested missing artist/song for a folder."
    @type t :: %__MODULE__{}
    defstruct [:artist, :song, :reason]
  end

  @doc "Suggests important artists/songs the library is likely MISSING for a folder. `opts`: `:count` (default 10)."
  @spec suggest_gaps(String.t(), keyword()) :: {:ok, [Gap.t()]} | {:error, term()}
  def suggest_gaps(folder_key, opts \\ []) do
    case GenreFolders.get_by_key(folder_key) do
      nil ->
        {:error, :unknown_folder}

      folder ->
        prompt = build_gaps_prompt(folder, artists_in(folder_key), Keyword.get(opts, :count, 10))

        with {:ok, %{"gaps" => gaps}} <- AI.complete(prompt, gaps_schema()) do
          {:ok,
           Enum.map(gaps, &%Gap{artist: &1["artist"], song: &1["song"], reason: &1["reason"]})}
        end
    end
  end

  @doc "Suggests songs that pair well with a track (same vibe/era), as `%Gap{}`s. `opts`: `:count` (default 8)."
  @spec suggest_matches(Track.t(), keyword()) :: {:ok, [Gap.t()]} | {:error, term()}
  def suggest_matches(%Track{} = track, opts \\ []) do
    track = Repo.preload(track, :soundcharts_song)
    prompt = build_matches_prompt(track, Keyword.get(opts, :count, 8))

    with {:ok, %{"matches" => list}} <- AI.complete(prompt, matches_schema()) do
      {:ok, Enum.map(list, &%Gap{artist: &1["artist"], song: &1["song"], reason: &1["reason"]})}
    end
  end

  @doc """
  Suggests a concise classification rubric (description) for a folder, written so
  the AI classifier can use it to assign tracks and kept distinct from the sibling
  folders. Returns the suggested text plus a one-phrase rationale for review.
  """
  @spec suggest_description(String.t(), keyword()) :: {:ok, Description.t()} | {:error, term()}
  def suggest_description(folder_key, _opts \\ []) do
    case GenreFolders.get_by_key(folder_key) do
      nil ->
        {:error, :unknown_folder}

      folder ->
        siblings = Enum.reject(GenreFolders.list(), &(&1.key == folder_key))
        prompt = build_description_prompt(folder, siblings, artists_in(folder_key))

        with {:ok, %{"description" => d, "rationale" => r}} <-
               AI.complete(prompt, description_schema()) do
          {:ok, %Description{description: d, rationale: r}}
        end
    end
  end

  # --- internals (moved verbatim from Beatgrid.AI) ---

  defp artists_in(folder_key) do
    from(t in Track,
      where: t.status == :present and t.genre_folder == ^folder_key and not is_nil(t.tag_artist),
      distinct: true,
      select: t.tag_artist
    )
    |> Repo.all()
  end

  defp build_gaps_prompt(folder, artists, count) do
    have = if artists == [], do: "(none yet)", else: Enum.join(artists, ", ")

    """
    You are a Brazilian-music curator helping a DJ fill gaps in ONE folder of their library.

    Folder: #{folder.display_name} — #{folder.description}

    Artists already in this folder: #{have}

    Suggest #{count} important artists/songs that fit THIS folder's specific style (read the
    description above — stay within it, don't drift into generic Brazilian music) and that the
    DJ is likely MISSING (not already in the list above). Guidelines:
    - Real, verifiable recordings only — never invent a song; use the canonical Artist + Song.
    - Favor essential, well-loved choices for the style, with a few deeper cuts mixed in.
    - Spread across different artists — don't stack several songs by the same one.
    - Use the proper Brazilian-Portuguese titles.

    For each: artist, song, and a one-line reason it belongs in this folder.
    """
  end

  defp build_matches_prompt(track, count) do
    song = track.soundcharts_song
    bpm = (song && song.tempo_bpm) || track.bpm_detected
    key = (song && song.camelot) || track.camelot_detected

    """
    You are a Brazilian-music DJ's crate assistant. Suggest #{count} songs that pair well in a SET with this
    track — same energy/era/feel, good to mix before or after it. Real, canonical recordings only; don't repeat
    the track itself.

    Track: #{track.tag_artist} — #{track.tag_title}
    Folder: #{track.genre_folder} · BPM: #{inspect(bpm)} · key: #{inspect(key)}

    For each: artist, song, and a one-line reason it pairs well.
    """
  end

  defp build_description_prompt(folder, siblings, artists) do
    current =
      if folder.description in [nil, ""],
        do: "(empty — needs a rubric)",
        else: folder.description

    have = if artists == [], do: "(none yet)", else: Enum.join(artists, ", ")

    sibling_lines =
      if siblings == [] do
        "(none)"
      else
        Enum.map_join(siblings, "\n", fn s ->
          "- #{s.display_name}: #{s.description || "(no rubric yet)"}"
        end)
      end

    """
    You are a Brazilian-music curator writing the classification rubric for ONE folder of a DJ's library.

    Folder: #{folder.display_name}
    Current rubric: #{current}

    Artists already in this folder: #{have}

    Sibling folders (the rubric must stay clearly DISTINCT from these):
    #{sibling_lines}

    Write a CONCISE classification rubric (2–4 sentences) for THIS folder: what belongs here, the
    sub-style / era / instrumentation that defines it, and a few representative Brazilian artists.
    Write it so an AI classifier can use it to assign tracks, and so it does NOT overlap with the
    sibling folders above. Use proper Brazilian-Portuguese names.

    Return the rubric text plus a one-short-phrase rationale on the choices you made.
    """
  end

  defp description_schema do
    Schema.object(%{"description" => Schema.string(), "rationale" => Schema.string()})
  end

  defp matches_schema, do: Schema.list_of("matches", recommendation_item())
  defp gaps_schema, do: Schema.list_of("gaps", recommendation_item())

  defp recommendation_item do
    %{"artist" => Schema.string(), "song" => Schema.string(), "reason" => Schema.string()}
  end
end
