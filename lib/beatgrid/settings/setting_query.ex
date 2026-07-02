defmodule Beatgrid.Settings.SettingQuery do
  @moduledoc "All reads for `Beatgrid.Settings.Setting`."

  alias Beatgrid.Repo
  alias Beatgrid.Settings.Setting

  @spec get_by_key(String.t()) :: Setting.t() | nil
  def get_by_key(key), do: Repo.get_by(Setting, key: key)

  @doc "Every stored override as a `%{key => value}` map (one select — the cache load)."
  @spec all_values() :: %{String.t() => term()}
  def all_values do
    Setting
    |> Repo.all()
    |> Map.new(fn %Setting{key: key, value: %{"v" => value}} -> {key, value} end)
  end
end
