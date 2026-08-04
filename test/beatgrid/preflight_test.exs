defmodule Beatgrid.PreflightTest do
  # async: false — the probe swaps the global repo config to aim at a dead port.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Beatgrid.Preflight

  setup do
    original = Application.fetch_env!(:beatgrid, Beatgrid.Repo)
    on_exit(fn -> Application.put_env(:beatgrid, Beatgrid.Repo, original) end)
    %{original: original}
  end

  test "reports :ok while the configured database answers" do
    assert :ok = Preflight.database()
  end

  test "an unreachable database is an error, never a raise", %{original: original} do
    Application.put_env(:beatgrid, Beatgrid.Repo, Keyword.put(original, :port, 59_999))

    assert capture_log(fn -> assert {:error, _reason} = Preflight.database() end) =~ ""
  end

  test "the failure message names the host and the command that fixes it", %{original: original} do
    Application.put_env(:beatgrid, Beatgrid.Repo, Keyword.put(original, :port, 59_999))

    log = capture_log(fn -> Preflight.log_unavailable(:econnrefused) end)

    assert log =~ "Banco de dados fora do ar"
    assert log =~ "59999"
    assert log =~ "docker compose up -d"
  end
end
