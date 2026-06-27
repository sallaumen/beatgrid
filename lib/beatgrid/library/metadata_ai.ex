defmodule Beatgrid.Library.MetadataAI do
  @moduledoc """
  AI for a track's own metadata: the canonical "Artist - Title" + whether the linked
  Soundcharts match is the same recording (`resolve_names/1`), and parsing artist/title
  out of raw YouTube titles (`parse_titles/1`). Claude only — no Soundcharts quota.
  """
  alias Beatgrid.AI
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

  @doc "Extracts `%ParsedTitle{}` from raw video titles (aligned to input order). `[]` → `{:ok, []}`."
  @spec parse_titles([String.t()]) :: {:ok, [ParsedTitle.t()]} | {:error, term()}
  def parse_titles([]), do: {:ok, []}

  def parse_titles(raw_titles) when is_list(raw_titles) do
    prompt = build_titles_prompt(raw_titles)

    with {:ok, %{"titles" => list}} <- AI.complete(prompt, titles_schema()) do
      {:ok, Enum.map(list, &%ParsedTitle{artist: &1["artist"], title: &1["title"]})}
    end
  end

  # --- resolve internals (moved verbatim from Beatgrid.AI) ---

  defp build_resolve_prompt(folders, tracks) do
    rubric = Enum.map_join(folders, "\n", fn f -> "- #{f.display_name}: #{f.description}" end)

    lines =
      tracks |> Enum.with_index(1) |> Enum.map_join("\n", fn {t, i} -> resolve_line(i, t) end)

    """
    You verify a DJ's Brazilian-music library metadata. For each track decide the correct
    canonical "Artist - Title" for THIS specific recording, and whether the Soundcharts match
    (when present) is the SAME recording — not merely the same song title by the original or a
    different artist. Covers/versions are common (e.g. a forró cover of an MPB classic is NOT the
    original). Prefer the file's OWN metadata (tags, filename, YouTube title); only override it
    with a clear reason. Use the folder context below to judge plausibility.

    Folder context:
    #{rubric}

    Tracks (one per number):
    #{lines}

    For each track return {index, same_recording (is the Soundcharts match the same recording? —
    false when there is no match or it's the original/another artist's version), artist, title,
    confidence 0.0-1.0, rationale (one short phrase)}.
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
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "resolutions" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "index" => %{"type" => "integer"},
              "same_recording" => %{"type" => "boolean"},
              "artist" => %{"type" => "string"},
              "title" => %{"type" => "string"},
              "confidence" => %{"type" => "number"},
              "rationale" => %{"type" => "string"}
            },
            "required" => [
              "index",
              "same_recording",
              "artist",
              "title",
              "confidence",
              "rationale"
            ]
          }
        }
      },
      "required" => ["resolutions"]
    }
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
    Drop noise like "(Official Video)", "[HD]", "Lyric Video", "ft.", channel names.
    Keep the real song title (including meaningful parentheticals). Return one entry
    per input, in the same order.

    Titles:
    #{lines}
    """
  end

  defp titles_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "titles" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "artist" => %{"type" => "string"},
              "title" => %{"type" => "string"}
            },
            "required" => ["artist", "title"]
          }
        }
      },
      "required" => ["titles"]
    }
  end
end
