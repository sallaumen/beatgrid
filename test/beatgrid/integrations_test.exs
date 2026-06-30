defmodule Beatgrid.IntegrationsTest do
  use ExUnit.Case, async: false
  alias Beatgrid.Integrations

  setup do
    prev = Application.get_env(:beatgrid, Beatgrid.Recognition.Audd)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, prev),
        else: Application.delete_env(:beatgrid, Beatgrid.Recognition.Audd)
    end)

    :ok
  end

  test "configured?(:audd) reflects api_token presence" do
    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: nil)
    refute Integrations.configured?(:audd)
    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: "tok")
    assert Integrations.configured?(:audd)
  end

  test "missing_env + label" do
    assert Integrations.missing_env(:audd) == "AUDD_API_TOKEN"
    assert Integrations.missing_env(:soundcharts) =~ "SOUNDCHARTS_APP_ID"
    assert Integrations.label(:audd) == "AudD"
  end
end
