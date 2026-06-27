defmodule Beatgrid.Soundcharts.Accounts do
  @moduledoc """
  Soundcharts credentials + per-account budget, enabling automatic failover
  across several limited free accounts.

  Calls go to the first configured account that still has quota; once its budget
  reaches the floor, the next account takes over (`active/0`). The budget is
  tracked per account via the `api_calls.account` ledger column, so one account
  running out never blocks the others.

  Accounts come from `config :beatgrid, Beatgrid.Soundcharts.Http, accounts: [...]`
  (set from the environment in `runtime.exs`). Entries missing credentials are
  dropped; with none configured (tests / a fresh checkout) a single synthetic
  account `"1"` is used, so the budget logic behaves exactly as it did before.
  """
  import Ecto.Query

  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts.ApiCall

  @default_base_url "https://customer.api.soundcharts.com"

  @type account :: %{id: String.t(), app_id: String.t() | nil, api_key: String.t() | nil}

  @doc "Configured accounts (id + creds) in failover order; a synthetic account 1 when none are set."
  @spec configured() :: [account()]
  def configured do
    (http_config(:accounts) || [])
    |> Enum.filter(&creds?/1)
    |> case do
      [] -> [%{id: "1", app_id: http_config(:app_id), api_key: http_config(:api_key)}]
      list -> list
    end
  end

  defp creds?(%{app_id: app_id, api_key: api_key}), do: present?(app_id) and present?(api_key)
  defp creds?(_), do: false
  defp present?(v), do: is_binary(v) and v != ""

  @doc "Base URL for the Soundcharts API."
  @spec base_url() :: String.t()
  def base_url, do: http_config(:base_url) || @default_base_url

  @doc "Per-account request cap (each free account gets its own ~1000)."
  @spec cap() :: integer()
  def cap, do: sc_config(:request_cap, 1000)

  @doc "Stop using an account once its remaining quota reaches this floor."
  @spec floor() :: integer()
  def floor, do: sc_config(:budget_floor, 50)

  @doc "First account whose remaining quota is above the floor, or nil if all are exhausted."
  @spec active() :: account() | nil
  def active do
    Enum.find(configured(), fn account -> account_budget(account.id).remaining > floor() end)
  end

  @doc """
  Budget for one account: the cap minus our own successful calls, floored by the
  latest `x-quota-remaining` header for that account — whichever is lower, so a
  misbehaving header can never let us overspend.
  """
  @spec account_budget(String.t()) :: %{
          id: String.t(),
          cap: integer(),
          used: non_neg_integer(),
          header_remaining: integer() | nil,
          remaining: integer()
        }
  def account_budget(id) do
    used =
      Repo.aggregate(
        from(c in ApiCall, where: c.success == true and c.account == ^id),
        :count,
        :id
      )

    header = latest_quota(id)
    base = cap() - used
    remaining = if is_integer(header), do: min(base, header), else: base
    %{id: id, cap: cap(), used: used, header_remaining: header, remaining: remaining}
  end

  @doc "Aggregate budget across every configured account — for the dashboard/CLI."
  @spec budget() :: %{
          cap: integer(),
          used: non_neg_integer(),
          header_remaining: integer() | nil,
          remaining: integer(),
          accounts: [map()]
        }
  def budget do
    per = Enum.map(configured(), &account_budget(&1.id))

    %{
      cap: cap() * length(per),
      used: Enum.sum(Enum.map(per, & &1.used)),
      header_remaining: Enum.reduce(per, nil, fn a, acc -> sum_opt(acc, a.header_remaining) end),
      remaining: Enum.sum(Enum.map(per, & &1.remaining)),
      accounts: per
    }
  end

  defp sum_opt(nil, nil), do: nil
  defp sum_opt(acc, value), do: (acc || 0) + (value || 0)

  defp latest_quota(id) do
    from(c in ApiCall,
      where: c.account == ^id and not is_nil(c.quota_remaining),
      order_by: [desc: c.occurred_at, desc: c.inserted_at],
      limit: 1,
      select: c.quota_remaining
    )
    |> Repo.one()
  end

  defp http_config(key),
    do: :beatgrid |> Application.get_env(Beatgrid.Soundcharts.Http, []) |> Keyword.get(key)

  defp sc_config(key, default),
    do: :beatgrid |> Application.get_env(Beatgrid.Soundcharts, []) |> Keyword.get(key, default)
end
