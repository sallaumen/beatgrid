defmodule Beatgrid.AI do
  @moduledoc """
  AI helpers for the Brazilian-music library. Provides:

    * `classify_tracks/1` / `reclassify/1` — genre-folder classification via the AI
      client; proposes `MoveSuggestion`s (source `:claude`) when the AI disagrees.
    * `resolve_names/1` — verifies the canonical "Artist - Title" and whether the
      linked Soundcharts match is the same recording (no Soundcharts quota).
    * `suggest_gaps/2` — suggests missing artists/songs for a folder.
    * `parse_titles/1` — extracts artist/title from raw YouTube titles.

  Nothing moves on disk until approved.
  """
  import Ecto.Query

  alias Beatgrid.Library.{GenreFolders, Track}
  alias Beatgrid.Organization
  alias Beatgrid.Repo

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.AI.Client, :adapter],
             Beatgrid.AI.ClaudeCli
           )

  @doc "Calls the AI client with the model default applied. The single AI entry point."
  @spec complete(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(prompt, schema, opts \\ []) do
    @adapter.complete(prompt, schema, Keyword.put_new(opts, :model, model()))
  end

  @type result :: %{
          track: Track.t(),
          folder: String.t(),
          confidence: float(),
          rationale: String.t()
        }

  @doc "Classifies a batch of tracks into genre folders via the AI client."
  @spec classify_tracks([Track.t()]) :: {:ok, [result()]} | {:error, term()}
  def classify_tracks(tracks) when is_list(tracks) do
    tracks = Repo.preload(tracks, :soundcharts_song)
    folders = GenreFolders.list()
    prompt = build_prompt(folders, tracks)
    schema = classification_schema(Enum.map(folders, & &1.key))

    with {:ok, %{"classifications" => list}} <- @adapter.complete(prompt, schema, model: model()) do
      {:ok, to_results(list, tracks)}
    end
  end

  @doc """
  Classifies every present track (in batches) and proposes a `:claude` move where
  the AI disagrees with the current folder. Returns a summary. `opts`: `:limit`,
  `:batch_size`.
  """
  @spec reclassify(keyword()) :: %{
          classified: non_neg_integer(),
          suggested: non_neg_integer(),
          agreed: non_neg_integer(),
          errors: non_neg_integer()
        }
  def reclassify(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, batch_size())
    batch_id = Uniq.UUID.uuid7()
    pending = pending_claude_track_ids()
    acc0 = %{classified: 0, suggested: 0, agreed: 0, errors: 0}

    (opts[:tracks] || present_tracks(opts))
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce(acc0, fn batch, acc ->
      case classify_tracks(batch) do
        {:ok, results} -> Enum.reduce(results, acc, &apply_result(&1, &2, pending, batch_id))
        {:error, _reason} -> %{acc | errors: acc.errors + length(batch)}
      end
    end)
  end

  @doc """
  Suggests important artists/songs the library is likely **missing** for a genre
  folder, given what it already has. Pure analysis — no disk, no Soundcharts quota.
  `opts`: `:count` (default 10).
  """
  @spec suggest_gaps(String.t(), keyword()) ::
          {:ok, [%{artist: String.t(), song: String.t(), reason: String.t()}]}
          | {:error, term()}
  def suggest_gaps(folder_key, opts \\ []) do
    case GenreFolders.get_by_key(folder_key) do
      nil ->
        {:error, :unknown_folder}

      folder ->
        prompt = build_gaps_prompt(folder, artists_in(folder_key), Keyword.get(opts, :count, 10))

        with {:ok, %{"gaps" => gaps}} <- @adapter.complete(prompt, gaps_schema(), model: model()) do
          {:ok, Enum.map(gaps, &%{artist: &1["artist"], song: &1["song"], reason: &1["reason"]})}
        end
    end
  end

  # --- internals ---

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
    You are a Brazilian-music curator helping a DJ fill gaps in their library.

    Folder: #{folder.display_name} — #{folder.description}

    Artists already in this folder: #{have}

    Suggest #{count} important artists/songs that fit this folder and that the DJ is
    likely MISSING (not already in the list above). Favor canonical, well-loved choices
    for the style. For each: artist, song, and a one-line reason.
    """
  end

  defp gaps_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "gaps" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "artist" => %{"type" => "string"},
              "song" => %{"type" => "string"},
              "reason" => %{"type" => "string"}
            },
            "required" => ["artist", "song", "reason"]
          }
        }
      },
      "required" => ["gaps"]
    }
  end

  defp apply_result(%{track: track, folder: folder} = result, acc, pending, batch_id) do
    acc = %{acc | classified: acc.classified + 1}

    cond do
      folder == track.genre_folder ->
        %{acc | agreed: acc.agreed + 1}

      MapSet.member?(pending, track.id) ->
        acc

      true ->
        {:ok, _suggestion} =
          Organization.create_suggestion(%{
            track_id: track.id,
            from_rel_path: track.rel_path,
            to_genre_folder: folder,
            source: :claude,
            confidence: result.confidence,
            reason: String.slice(result.rationale || "", 0, 250),
            batch_id: batch_id
          })

        %{acc | suggested: acc.suggested + 1}
    end
  end

  defp to_results(list, tracks) do
    list
    |> Enum.map(fn item ->
      case Enum.at(tracks, (item["index"] || 0) - 1) do
        nil ->
          nil

        track ->
          %{
            track: track,
            folder: item["folder"],
            confidence: item["confidence"],
            rationale: item["rationale"]
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp present_tracks(opts) do
    query = from(t in Track, where: t.status == :present, order_by: [asc: :rel_path])
    query = if limit = opts[:limit], do: limit(query, ^limit), else: query

    query
    |> preload(:soundcharts_song)
    |> Repo.all()
  end

  defp pending_claude_track_ids do
    [status: :pending, source: :claude]
    |> Organization.list_by()
    |> MapSet.new(& &1.track_id)
  end

  defp build_prompt(folders, tracks) do
    rubric =
      Enum.map_join(folders, "\n", fn f -> "- #{f.key} — #{f.display_name}: #{f.description}" end)

    lines = tracks |> Enum.with_index(1) |> Enum.map_join("\n", fn {t, i} -> track_line(i, t) end)

    """
    You are classifying a DJ's Brazilian music library (forró / MPB / samba) into genre
    folders. Assign each track to exactly ONE folder by its key, using the rubric. Use the
    artist, title and Soundcharts signals (subgenres, BPM, energy, year). When a track is a
    songwriter/MPB act rather than forró, prefer `mpb`. Distinguish the forró sub-styles by
    the rubric; when unsure between two, pick the better fit and lower the confidence.

    Folders:
    #{rubric}

    Tracks (classify each by its number):
    #{lines}

    For each track return {index, folder (one of the keys above), confidence 0.0–1.0,
    rationale (one short phrase)}.
    """
  end

  defp track_line(index, track) do
    song = track.soundcharts_song

    "#{index}. artist=#{inspect(track.tag_artist)} title=#{inspect(track.tag_title)} current_folder=#{inspect(track.genre_folder)}#{song_signals(song)}"
  end

  defp song_signals(%{} = song) do
    year = song.release_date && song.release_date.year

    " subgenres=#{inspect(song.subgenres)} bpm=#{inspect(song.tempo_bpm)}" <>
      " energy=#{inspect(song.energy)} year=#{inspect(year)}"
  end

  defp song_signals(_song), do: ""

  defp classification_schema(keys) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "classifications" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "index" => %{"type" => "integer"},
              "folder" => %{"type" => "string", "enum" => keys},
              "confidence" => %{"type" => "number"},
              "rationale" => %{"type" => "string"}
            },
            "required" => ["index", "folder", "confidence", "rationale"]
          }
        }
      },
      "required" => ["classifications"]
    }
  end

  def model, do: config(:model, "sonnet")
  def batch_size, do: config(:batch_size, 15)

  defp config(key, default),
    do: :beatgrid |> Application.get_env(Beatgrid.AI, []) |> Keyword.get(key, default)
end
