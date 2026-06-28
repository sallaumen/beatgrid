defmodule Beatgrid.Soundcharts.AccountsTest do
  # async: false — mutates the Soundcharts app env to simulate configured accounts.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Soundcharts
  alias Beatgrid.Soundcharts.{Accounts, ApiCall, Http, Mock, Response}

  setup do
    prev_http = Application.get_env(:beatgrid, Beatgrid.Soundcharts.Http)
    prev_sc = Application.get_env(:beatgrid, Beatgrid.Soundcharts)

    on_exit(fn ->
      restore(Beatgrid.Soundcharts.Http, prev_http)
      restore(Beatgrid.Soundcharts, prev_sc)
    end)

    :ok
  end

  defp restore(mod, nil), do: Application.delete_env(:beatgrid, mod)
  defp restore(mod, prev), do: Application.put_env(:beatgrid, mod, prev)

  defp put_accounts(list),
    do:
      Application.put_env(:beatgrid, Beatgrid.Soundcharts.Http,
        base_url: "http://x",
        accounts: list
      )

  defp put_budget(cap, floor),
    do:
      Application.put_env(:beatgrid, Beatgrid.Soundcharts, request_cap: cap, budget_floor: floor)

  defp log(account, quota) do
    Repo.insert!(
      ApiCall.changeset(%ApiCall{}, %{
        provider: "soundcharts",
        account: account,
        endpoint: "x",
        success: true,
        quota_remaining: quota,
        occurred_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
    )
  end

  test "configured/0 keeps only accounts with both credentials, in order" do
    put_accounts([
      %{id: "1", app_id: "a1", api_key: "k1"},
      %{id: "2", app_id: nil, api_key: nil},
      %{id: "3", app_id: "a3", api_key: "k3"}
    ])

    assert Enum.map(Accounts.configured(), & &1.id) == ["1", "3"]
  end

  test "configured/0 falls back to a synthetic account 1 when none are configured" do
    put_accounts([])
    assert [%{id: "1"}] = Accounts.configured()
  end

  test "account_budget/1 counts only that account's successful calls" do
    put_accounts([
      %{id: "1", app_id: "a1", api_key: "k1"},
      %{id: "2", app_id: "a2", api_key: "k2"}
    ])

    put_budget(1000, 50)
    log("1", nil)
    log("1", nil)
    log("2", nil)

    assert Accounts.account_budget("1").used == 2
    assert Accounts.account_budget("2").used == 1
  end

  test "active/0 fails over to account 2 once account 1 hits the floor" do
    put_accounts([
      %{id: "1", app_id: "a1", api_key: "k1"},
      %{id: "2", app_id: "a2", api_key: "k2"}
    ])

    put_budget(100, 50)

    # All quota left → account 1 is active.
    assert Accounts.active().id == "1"

    # Account 1's header drops below the floor → fail over to account 2.
    log("1", 40)
    assert Accounts.active().id == "2"

    # Account 2 also drops → nothing active (callers get :budget_exhausted).
    log("2", 30)
    assert Accounts.active() == nil
  end

  test "resolve_track bills its calls to the active account (fails over 1 → 2)" do
    put_accounts([
      %{id: "1", app_id: "a1", api_key: "k1"},
      %{id: "2", app_id: "a2", api_key: "k2"}
    ])

    put_budget(100, 50)
    # Account 1 is exhausted (header 40 < floor 50) → account 2 takes over.
    log("1", 40)

    track = insert(:track, tag_artist: "Y", tag_title: "X", norm_artist: "y", norm_title: "x")

    stub(Mock, :search_song, fn _term ->
      {:ok,
       %Response{
         data: [%{uuid: "u", name: "X", credit_name: "Y", release_date: nil}],
         quota_remaining: 80,
         status: 200
       }}
    end)

    stub(Mock, :get_song, fn "u" ->
      {:ok,
       %Response{
         data: %{sc_uuid: "u", name: "X", credit_name: "Y", raw: %{}},
         quota_remaining: 79,
         status: 200
       }}
    end)

    assert {:ok, _song} = Soundcharts.resolve_track(track)

    # Both new successful calls were billed to account 2, not the exhausted account 1.
    assert Accounts.account_budget("2").used == 2
  end

  test "the Http adapter refuses with :no_credentials instead of a cryptic 401" do
    # No account has credentials (e.g. the .env wasn't loaded) → don't send empty
    # auth headers and get a 401 per track; refuse up front with a clear error.
    put_accounts([%{id: "1", app_id: nil, api_key: nil}])

    assert {:error, :no_credentials} = Http.search_song("anything")
  end
end
