defmodule Beatgrid.AI do
  @moduledoc """
  AI helpers for the Brazilian-music library. Provides:

    * `suggest_gaps/2` — suggests missing artists/songs for a folder.

  Nothing moves on disk until approved.
  """
  import Ecto.Query

  alias Beatgrid.Library.{GenreFolders, Track}
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

  def model, do: config(:model, "sonnet")
  def batch_size, do: config(:batch_size, 15)

  defp config(key, default),
    do: :beatgrid |> Application.get_env(Beatgrid.AI, []) |> Keyword.get(key, default)
end
