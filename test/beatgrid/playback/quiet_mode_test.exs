defmodule Beatgrid.Playback.QuietModeTest do
  use ExUnit.Case, async: false

  alias Beatgrid.Playback.QuietMode

  defmodule Controller do
    def pause(scope) do
      send(test_pid(), {:pause, scope})
      :ok
    end

    def resume(scope) do
      send(test_pid(), {:resume, scope})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:beatgrid, :quiet_mode_test_pid)
    end
  end

  setup do
    Application.put_env(:beatgrid, :quiet_mode_test_pid, self())
    start_supervised!({QuietMode, name: __MODULE__.Server, controller: Controller, scope: :all})
    :ok
  end

  test "activate pauses background work once" do
    assert :ok = QuietMode.activate(__MODULE__.Server)
    assert :ok = QuietMode.activate(__MODULE__.Server)

    assert_receive {:pause, :all}
    refute_receive {:pause, :all}, 50
    assert QuietMode.active?(__MODULE__.Server)
  end

  test "deactivate resumes background work once" do
    assert :ok = QuietMode.activate(__MODULE__.Server)
    assert_receive {:pause, :all}

    assert :ok = QuietMode.deactivate(__MODULE__.Server)
    assert :ok = QuietMode.deactivate(__MODULE__.Server)

    assert_receive {:resume, :all}
    refute_receive {:resume, :all}, 50
    refute QuietMode.active?(__MODULE__.Server)
  end
end
