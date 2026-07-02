defmodule Beatgrid.Soundcharts.Http do
  @moduledoc """
  Real Soundcharts adapter (Req). Authenticates with the legacy
  `x-app-id` / `x-api-key` headers and normalizes the wire shapes into the
  `Response` the context expects. Credentials come from the active account
  (`Beatgrid.Soundcharts.Accounts`), so calls fail over across accounts; `base_url`
  / `req_options` come from `config :beatgrid, #{inspect(__MODULE__)}` (runtime.exs).
  """
  @behaviour Beatgrid.Soundcharts.Client

  alias Beatgrid.Soundcharts.{Accounts, Response}

  @search_path "/api/v2/song/search/"
  @song_path "/api/v2.25/song/"

  @impl true
  def search_song(term) do
    with_account(fn account ->
      account
      |> client()
      |> Req.get(url: @search_path <> URI.encode(term), params: [offset: 0, limit: 20])
      |> handle(account, &parse_search/1)
    end)
  end

  @impl true
  def get_song(uuid) do
    with_account(fn account ->
      account
      |> client()
      |> Req.get(url: @song_path <> uuid)
      |> handle(account, &parse_song/1)
    end)
  end

  # --- request plumbing ---

  # Use the active account's credentials. The context already guards the budget, so
  # nil only happens when every account is exhausted. A configured-but-credential-less
  # account (e.g. the .env wasn't loaded) would otherwise send empty auth headers and
  # get a cryptic 401 per track — refuse up front with a named error instead, and
  # don't hammer the API with unauthenticated requests.
  defp with_account(fun) do
    case Accounts.active() do
      nil -> {:error, :budget_exhausted}
      account -> if credentialed?(account), do: fun.(account), else: {:error, :no_credentials}
    end
  end

  defp credentialed?(%{app_id: app_id, api_key: api_key}),
    do: is_binary(app_id) and app_id != "" and is_binary(api_key) and api_key != ""

  defp client(account) do
    # Explicit request timeouts so a single Soundcharts call can never hang a job
    # indefinitely (this is Req's default, made explicit; overridable via :req_options).
    [
      base_url: Accounts.base_url(),
      headers: headers(account),
      connect_options: [timeout: 15_000],
      receive_timeout: 15_000
    ]
    |> Keyword.merge(config(:req_options) || [])
    |> Req.new()
  end

  # SECRETS: these custom headers carry the API credentials and are NOT covered
  # by Req's authorization-header redaction — never log/inspect the built request
  # (errors log status + body only; keep it that way).
  defp headers(account) do
    [{"x-app-id", account.app_id}, {"x-api-key", account.api_key}]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp handle({:ok, %Req.Response{status: status} = resp}, account, parser)
       when status in 200..299 do
    {:ok,
     %Response{
       data: parser.(resp.body),
       quota_remaining: quota(resp),
       status: status,
       account: account.id
     }}
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}, _account, _parser) do
    {:error, {:http_error, status, body}}
  end

  defp handle({:error, reason}, _account, _parser), do: {:error, reason}

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

  defp parse_song(%{"object" => object}) when is_map(object), do: attrs_from_object(object)
  defp parse_song(_body), do: %{}

  @doc """
  Maps a Soundcharts song `object` map to `Song` attrs. Public so a backfill can
  re-derive columns from the cached `raw` object without spending quota.
  """
  @spec attrs_from_object(map()) :: map()
  def attrs_from_object(object) when is_map(object) do
    audio = object["audio"] || %{}
    main_artist = object |> Map.get("mainArtists", []) |> List.first(%{})

    %{
      sc_uuid: object["uuid"],
      isrc: get_in(object, ["isrc", "value"]),
      name: object["name"],
      credit_name: object["creditName"],
      release_date: parse_date(object["releaseDate"]),
      label: object |> Map.get("labels", []) |> List.first(%{}) |> Map.get("name"),
      genres: parse_genres(object["genres"], "root"),
      subgenres: parse_genres(object["genres"], "sub"),
      duration_seconds: object["duration"],
      language_code: object["languageCode"],
      image_url: object["imageUrl"],
      sc_artist_uuid: main_artist["uuid"],
      sc_artist_name: main_artist["name"],
      tempo_bpm: audio["tempo"],
      music_key: audio["key"],
      music_mode: audio["mode"],
      time_signature: audio["timeSignature"],
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

  def attrs_from_object(_object), do: %{}

  # Soundcharts genres are `[%{"root" => "latin", "sub" => ["forró", …]}]`.
  defp parse_genres(genres, "root") when is_list(genres) do
    Enum.flat_map(genres, fn
      %{"root" => root} when is_binary(root) -> [root]
      name when is_binary(name) -> [name]
      _other -> []
    end)
  end

  defp parse_genres(genres, "sub") when is_list(genres) do
    Enum.flat_map(genres, fn
      %{"sub" => subs} when is_list(subs) -> Enum.filter(subs, &is_binary/1)
      _other -> []
    end)
  end

  defp parse_genres(_genres, _key), do: []

  defp parse_date(nil), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp config(key), do: :beatgrid |> Application.get_env(__MODULE__, []) |> Keyword.get(key)
end
