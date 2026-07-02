defmodule Beatgrid.Library.MetadataAI do
  @moduledoc """
  AI for a track's own metadata: the canonical "Artist - Title" + whether the linked
  Soundcharts match is the same recording (`resolve_names/1`), and parsing artist/title
  out of raw YouTube titles (`parse_titles/1`). Claude only — no Soundcharts quota.
  """
  require Logger

  alias Beatgrid.AI
  alias Beatgrid.AI.Schema
  alias Beatgrid.Library.{GenreFolders, Track}
  alias Beatgrid.Repo

  defmodule Resolution do
    @moduledoc "Per-track name-resolution verdict."
    @type t :: %__MODULE__{}
    defstruct [:track, :same_recording, :artist, :title, :confidence, :rationale]
  end

  defmodule ParsedTitle do
    @moduledoc "Artist/title parsed from a raw video title."
    @type t :: %__MODULE__{}
    defstruct [:artist, :title]
  end

  @doc """
  Verifies/derives the canonical "Artist - Title" for each track and whether the linked
  Soundcharts match is the SAME recording (vs. a cover/original by another artist).
  """
  @spec resolve_names([Track.t()]) :: {:ok, [Resolution.t()]} | {:error, term()}
  def resolve_names(tracks) when is_list(tracks) do
    tracks = Repo.preload(tracks, :soundcharts_song)
    folders = GenreFolders.list()
    prompt = build_resolve_prompt(folders, tracks)

    with {:ok, %{"resolutions" => list}} <- AI.complete(prompt, resolve_schema()) do
      {:ok, to_resolutions(list, tracks)}
    end
  end

  @doc """
  Extracts `%ParsedTitle{}` from raw video titles, aligned to input order. Runs in
  batches (one AI call each) so a big list can't blow up a single prompt; a batch
  that fails or comes back misaligned is logged and yields nil-field placeholders
  (callers skip those), so one bad batch never derails the rest. Always `{:ok, list}`.
  """
  @spec parse_titles([String.t()], (non_neg_integer(), non_neg_integer() -> any())) ::
          {:ok, [ParsedTitle.t()]}
  def parse_titles(raw_titles, on_progress \\ fn _done, _total -> :ok end)

  def parse_titles([], _on_progress), do: {:ok, []}

  def parse_titles(raw_titles, on_progress) when is_list(raw_titles) do
    total = length(raw_titles)

    {parsed, _done} =
      raw_titles
      |> Enum.chunk_every(AI.batch_size())
      |> Enum.flat_map_reduce(0, fn chunk, done ->
        result = parse_titles_chunk(chunk)
        done = done + length(chunk)
        on_progress.(done, total)
        {result, done}
      end)

    {:ok, parsed}
  end

  defp parse_titles_chunk(chunk) do
    prompt = build_titles_prompt(chunk)

    case AI.complete(prompt, titles_schema()) do
      {:ok, %{"titles" => list}} when length(list) == length(chunk) ->
        Enum.map(list, &%ParsedTitle{artist: &1["artist"], title: &1["title"]})

      other ->
        Logger.warning(
          "MetadataAI.parse_titles: batch of #{length(chunk)} failed: #{inspect(other)}"
        )

        Enum.map(chunk, fn _ -> %ParsedTitle{artist: nil, title: nil} end)
    end
  end

  # --- resolve internals (moved verbatim from Beatgrid.AI) ---

  defp build_resolve_prompt(folders, tracks) do
    rubric = Enum.map_join(folders, "\n", fn f -> "- #{f.display_name}: #{f.description}" end)

    lines =
      tracks |> Enum.with_index(1) |> Enum.map_join("\n", fn {t, i} -> resolve_line(i, t) end)

    """
    You verify a DJ's Brazilian-music library metadata. For EACH track, decide two things:

    1. The correct canonical "Artist - Title" for THIS SPECIFIC recording — the file the DJ
       actually has. "Artist" means the PERFORMER of this recording, NOT the composer and NOT
       whoever made the original or most famous version.
    2. same_recording: is the linked Soundcharts match the SAME recording as this file — same
       performer, same version — or merely the same song title by a different/original artist?

    Covers and versions are everywhere in this scene (forró and MPB acts constantly re-record
    each other's songs — e.g. a forró band covering an MPB classic, or a duo covering a pop hit).
    So a Soundcharts hit on the song TITLE is NOT enough: if the performer differs from the
    file's evidence, it is a DIFFERENT recording (same_recording=false), and the artist must be
    the file's performer, not the match's.

    Evidence priority — the file is the source of truth for WHICH recording this is:
    - Trust the file's OWN signals first: tags (file_artist/file_title), filename, and
      especially youtube_title (where the track came from).
    - When youtube_title (or the tags) name a performer that differs from the Soundcharts
      match's artist, treat it as a strong cover signal → keep the file's performer and set
      same_recording=false.
    - Use the Soundcharts match (artist/title/subgenres/year) and the folder context only to
      confirm plausibility or fix obvious tag noise — never to overwrite a clearly-named
      performer with the original/most-famous artist.

    Calibrate confidence: high (>= 0.8) only when the file evidence is clear AND consistent;
    medium when you had to choose between conflicting signals; low when the metadata is sparse
    or contradictory.

    Folder context:
    #{rubric}

    Tracks (one per number):
    #{lines}

    For each track return {index, same_recording (true ONLY if the Soundcharts match is this
    exact recording by this performer; false when there is no match, or it's the original /
    another artist's version), artist (the performer of THIS recording), title, confidence
    0.0-1.0, rationale (one short phrase)}.
    """
  end

  defp resolve_line(index, track) do
    song = track.soundcharts_song
    yt = (track.raw_tags || %{})["youtube_title"]

    "#{index}. file_artist=#{inspect(track.tag_artist)} file_title=#{inspect(track.tag_title)}" <>
      " filename=#{inspect(track.filename)} youtube_title=#{inspect(yt)}" <>
      " folder=#{inspect(track.genre_folder)}#{match_signals(song)}"
  end

  defp match_signals(%{} = song) do
    year = song.release_date && song.release_date.year

    " | soundcharts_match: artist=#{inspect(song.credit_name)} title=#{inspect(song.name)}" <>
      " subgenres=#{inspect(song.subgenres)} year=#{inspect(year)}"
  end

  defp match_signals(_song), do: " | soundcharts_match: none"

  defp resolve_schema do
    Schema.list_of("resolutions", %{
      "index" => Schema.integer(),
      "same_recording" => Schema.boolean(),
      "artist" => Schema.string(),
      "title" => Schema.string(),
      "confidence" => Schema.number(),
      "rationale" => Schema.string()
    })
  end

  defp to_resolutions(list, tracks) do
    list
    |> Enum.map(fn item ->
      case Enum.at(tracks, (item["index"] || 0) - 1) do
        nil ->
          nil

        track ->
          %Resolution{
            track: track,
            same_recording: item["same_recording"],
            artist: item["artist"],
            title: item["title"],
            confidence: item["confidence"],
            rationale: item["rationale"]
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # --- parse_titles internals (moved verbatim) ---

  defp build_titles_prompt(titles) do
    lines = titles |> Enum.with_index(1) |> Enum.map_join("\n", fn {t, i} -> "#{i}. #{t}" end)

    """
    Extract the music artist and song title from each raw YouTube video title below.

    - Drop noise: "(Official Video)", "(Clipe Oficial)", "[HD]"/"[4K]", "Lyric Video",
      "Áudio Oficial", remaster/year tags, and channel or label names.
    - The artist is the MAIN performer. Drop featured guests ("ft."/"feat."/"part.") from the
      artist field — keep only the lead act.
    - Keep the real song title, including meaningful parentheticals that are part of it
      ("(Ao Vivo)", "(Acústico)", a subtitle), but not promo noise.
    - Titles are usually "Artista - Título"; if the order looks reversed, use your knowledge of
      Brazilian artists to put the performer in `artist`.
    - Return one entry per input, in the same order.

    Titles:
    #{lines}
    """
  end

  defp titles_schema do
    Schema.list_of("titles", %{"artist" => Schema.string(), "title" => Schema.string()})
  end
end
