defmodule Beatgrid.Settings do
  @moduledoc """
  Runtime-tunable settings: a tiny key/value layer over the app config. `get/2`
  returns the stored override or the caller's (config-driven) default, so every
  tunable keeps working with zero rows and changes take effect without a restart
  once `put/2` stores an override.

  All overrides are cached in ONE `:persistent_term` entry, loaded with a single
  select on first read and erased on every `put/2` — hot paths (per-row reads in
  the UI) never touch the DB. Single node, per the project scope.

  Tests that call `put/2` must `on_exit(fn -> Beatgrid.Settings.invalidate() end)`
  — the sandbox rolls the row back, but the cache is global.
  """

  alias Beatgrid.Repo
  alias Beatgrid.Settings.{Setting, SettingQuery}

  @cache_key {__MODULE__, :cache}

  @doc "The stored override for `key`, or `default` when none is set."
  @spec get(atom() | String.t(), term()) :: term()
  def get(key, default) do
    Map.get(cache(), to_string(key), default)
  end

  @doc "Stores (or replaces) the override for `key` and refreshes the cache."
  @spec put(atom() | String.t(), term()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value) do
    key = to_string(key)
    existing = SettingQuery.get_by_key(key)

    result =
      (existing || %Setting{})
      |> Setting.changeset(%{key: key, value: %{"v" => value}})
      |> Repo.insert_or_update()

    invalidate()
    result
  end

  @doc "Removes the override for `key` (falling back to the default) and refreshes the cache."
  @spec delete(atom() | String.t()) :: :ok
  def delete(key) do
    case SettingQuery.get_by_key(to_string(key)) do
      nil -> :ok
      setting -> with {:ok, _} <- Repo.delete(setting), do: :ok
    end
    |> tap(fn _ -> invalidate() end)
  end

  @doc "Drops the cache so the next read reloads from the DB."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp cache do
    case :persistent_term.get(@cache_key, :miss) do
      :miss ->
        values = SettingQuery.all_values()
        :persistent_term.put(@cache_key, values)
        values

      values ->
        values
    end
  end
end
