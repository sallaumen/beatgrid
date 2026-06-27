defmodule Beatgrid.Organization.ClassificationAI do
  @moduledoc """
  AI genre classification. Builds a rubric prompt from the genre folders + each track's
  tags and Soundcharts data, asks the AI client for a verdict, and turns disagreements
  with the current folder into pending `:claude` `MoveSuggestion`s — reusing approve →
  apply → undo. Nothing moves on disk until approved.
  """
  import Ecto.Query

  alias Beatgrid.AI
  alias Beatgrid.Library.{GenreFolders, Track}
  alias Beatgrid.Organization
  alias Beatgrid.Repo

  defmodule Verdict do
    @moduledoc "Per-track classification verdict."
    @type t :: %__MODULE__{}
    defstruct [:track, :folder, :confidence, :rationale]
  end

  @doc "Classifies a batch of tracks into genre folders via the AI client."
  @spec classify_tracks([Track.t()]) :: {:ok, [Verdict.t()]} | {:error, term()}
  def classify_tracks(tracks) when is_list(tracks) do
    tracks = Repo.preload(tracks, :soundcharts_song)
    folders = GenreFolders.list()
    prompt = build_prompt(folders, tracks)
    schema = classification_schema(Enum.map(folders, & &1.key))

    with {:ok, %{"classifications" => list}} <- AI.complete(prompt, schema) do
      {:ok, to_results(list, tracks)}
    end
  end

  @doc """
  Classifies every present track (in batches) and proposes a `:claude` move where the AI
  disagrees with the current folder. `opts`: `:limit`, `:batch_size`, `:tracks`.
  """
  @spec reclassify(keyword()) :: %{
          classified: non_neg_integer(),
          suggested: non_neg_integer(),
          agreed: non_neg_integer(),
          errors: non_neg_integer()
        }
  def reclassify(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, AI.batch_size())
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

  # --- internals (moved verbatim from Beatgrid.AI) ---

  defp apply_result(%Verdict{track: track, folder: folder} = result, acc, pending, batch_id) do
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
          %Verdict{
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
end
