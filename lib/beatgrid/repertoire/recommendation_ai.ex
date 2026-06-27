defmodule Beatgrid.Repertoire.RecommendationAI do
  @moduledoc """
  AI curation/recommendation: artists/songs a genre folder is likely MISSING
  (`suggest_gaps/2`). Pure analysis — no disk, no Soundcharts quota. (Future home for
  "songs that match this one" and "fill a genre rubric with AI".)
  """
  import Ecto.Query

  alias Beatgrid.AI
  alias Beatgrid.Library.{GenreFolders, Track}
  alias Beatgrid.Repo

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
end
