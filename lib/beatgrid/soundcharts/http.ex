defmodule Beatgrid.Soundcharts.Http do
  @moduledoc """
  Real Soundcharts adapter (Req). Authenticates with the legacy
  `x-app-id` / `x-api-key` headers and normalizes the wire shapes into the
  `Response` the context expects. Credentials and `base_url` come from
  `config :beatgrid, #{inspect(__MODULE__)}` (set in `runtime.exs`).
  """
  @behaviour Beatgrid.Soundcharts.Client

  alias Beatgrid.Soundcharts.Response

  @search_path "/api/v2/song/search/"
  @song_path "/api/v2.25/song/"

  @impl true
  def search_song(term) do
    client()
    |> Req.get(url: @search_path <> URI.encode(term), params: [offset: 0, limit: 20])
    |> handle(&parse_search/1)
  end

  @impl true
  def get_song(uuid) do
    client()
    |> Req.get(url: @song_path <> uuid)
    |> handle(&parse_song/1)
  end

  # --- request plumbing ---

  defp client do
    [base_url: config(:base_url), headers: headers()]
    |> Keyword.merge(config(:req_options) || [])
    |> Req.new()
  end

  defp headers do
    [{"x-app-id", config(:app_id)}, {"x-api-key", config(:api_key)}]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp handle({:ok, %Req.Response{status: status} = resp}, parser) when status in 200..299 do
    {:ok, %Response{data: parser.(resp.body), quota_remaining: quota(resp), status: status}}
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}, _parser) do
    {:error, {:http_error, status, body}}
  end

  defp handle({:error, reason}, _parser), do: {:error, reason}

  defp quota(resp) do
    with [value | _] <- Req.Response.get_header(resp, "x-quota-remaining"),
         {n, _rest} <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end

  # --- parsers ---

  defp parse_search(%{"items" => items}) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        uuid: item["uuid"],
        name: item["name"],
        credit_name: item["creditName"],
        release_date: parse_date(item["releaseDate"])
      }
    end)
  end

  defp parse_search(_body), do: []

  defp parse_song(%{"object" => object}) when is_map(object) do
    audio = object["audio"] || %{}

    %{
      sc_uuid: object["uuid"],
      isrc: get_in(object, ["isrc", "value"]),
      name: object["name"],
      credit_name: object["creditName"],
      release_date: parse_date(object["releaseDate"]),
      label: object |> Map.get("labels", []) |> List.first(%{}) |> Map.get("name"),
      genres: parse_genres(object["genres"]),
      tempo_bpm: audio["tempo"],
      music_key: audio["key"],
      music_mode: audio["mode"],
      energy: audio["energy"],
      valence: audio["valence"],
      danceability: audio["danceability"],
      acousticness: audio["acousticness"],
      instrumentalness: audio["instrumentalness"],
      liveness: audio["liveness"],
      loudness: audio["loudness"],
      speechiness: audio["speechiness"],
      raw: object
    }
  end

  defp parse_song(_body), do: %{}

  defp parse_genres(genres) when is_list(genres), do: Enum.flat_map(genres, &genre_name/1)
  defp parse_genres(_genres), do: []

  defp genre_name(name) when is_binary(name), do: [name]
  defp genre_name(%{"root" => root}) when is_binary(root), do: [root]
  defp genre_name(%{"name" => name}) when is_binary(name), do: [name]
  defp genre_name(_other), do: []

  defp parse_date(nil), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp config(key), do: :beatgrid |> Application.get_env(__MODULE__, []) |> Keyword.get(key)
end
