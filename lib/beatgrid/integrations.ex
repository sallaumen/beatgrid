defmodule Beatgrid.Integrations do
  @moduledoc """
  Single source of truth for whether an external integration is configured. The UI
  consults this to disable + explain buttons whose integration isn't set up.
  """
  alias Beatgrid.Soundcharts.Accounts

  @type key :: :audd | :soundcharts

  @spec configured?(key()) :: boolean()
  def configured?(:audd), do: present?(audd_token())

  def configured?(:soundcharts) do
    Accounts.configured()
    |> Enum.any?(fn acc -> present?(acc[:app_id]) and present?(acc[:api_key]) end)
  end

  @spec missing_env(key()) :: String.t()
  def missing_env(:audd), do: "AUDD_API_TOKEN"
  def missing_env(:soundcharts), do: "SOUNDCHARTS_APP_ID + SOUNDCHARTS_API_KEY"

  @spec label(key()) :: String.t()
  def label(:audd), do: "AudD"
  def label(:soundcharts), do: "Soundcharts"

  defp audd_token, do: Application.get_env(:beatgrid, Beatgrid.Recognition.Audd, [])[:api_token]
  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
