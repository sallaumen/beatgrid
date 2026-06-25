defmodule Beatgrid.Soundcharts.Client do
  @moduledoc """
  Port contract for the Soundcharts API. The real adapter is `Soundcharts.Http`;
  tests use `Soundcharts.Mock`.

  Each call returns a `Response` carrying the parsed data plus `quota_remaining`,
  so the context can write the budget ledger.
  """
  alias Beatgrid.Soundcharts.Response

  @doc "Search songs by name. `data` is a list of `%{uuid, name, credit_name, release_date}`."
  @callback search_song(term :: String.t()) :: {:ok, Response.t()} | {:error, term()}

  @doc "Fetch full song metadata by UUID. `data` is a map of `Soundcharts.Song` attrs."
  @callback get_song(uuid :: String.t()) :: {:ok, Response.t()} | {:error, term()}
end
