defmodule Beatgrid.Soundcharts.BudgetTest do
  # async: false — these tests mutate the global :beatgrid app env (cap/floor).
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Repo
  alias Beatgrid.Soundcharts
  alias Beatgrid.Soundcharts.{ApiCall, Mock}

  setup do
    original = Application.get_env(:beatgrid, Soundcharts)
    on_exit(fn -> Application.put_env(:beatgrid, Soundcharts, original) end)
    :ok
  end

  defp configure(opts), do: Application.put_env(:beatgrid, Soundcharts, opts)

  defp log_success(quota, occurred_at) do
    %ApiCall{}
    |> ApiCall.changeset(%{
      provider: "soundcharts",
      endpoint: "song/get",
      success: true,
      quota_remaining: quota,
      occurred_at: DateTime.truncate(occurred_at, :second)
    })
    |> Repo.insert!()
  end

  @t0 ~U[2026-06-25 10:00:00Z]

  test "remaining counts our own successful calls against the cap" do
    configure(request_cap: 10, budget_floor: 2)
    for n <- 1..3, do: log_success(nil, DateTime.add(@t0, n))

    budget = Soundcharts.budget()
    assert budget.used == 3
    assert budget.header_remaining == nil
    assert budget.remaining == 7
  end

  test "remaining never exceeds the latest x-quota-remaining header" do
    configure(request_cap: 1000, budget_floor: 50)
    log_success(900, @t0)
    log_success(5, DateTime.add(@t0, 60))

    budget = Soundcharts.budget()
    assert budget.header_remaining == 5
    # min(1000 - 2 used, header 5) → the header wins
    assert budget.remaining == 5
  end

  test "resolve_track refuses below the floor and makes no API calls" do
    configure(request_cap: 3, budget_floor: 2)
    for n <- 1..2, do: log_success(nil, DateTime.add(@t0, n))
    # used 2, remaining 1, floor 2 → exhausted

    track = insert(:track, tag_title: "Anything")

    # No Mox expectation: if the guard let a call through, Mock would raise.
    assert {:error, :budget_exhausted} = Soundcharts.resolve_track(track)
    refute_received _
    verify!(Mock)
  end
end
