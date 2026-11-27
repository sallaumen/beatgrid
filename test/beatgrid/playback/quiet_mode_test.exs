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

  test "the activator dying without deactivating resumes background work" do
    owner =
      spawn(fn ->
        QuietMode.activate(__MODULE__.Server)

        receive do
          :die -> :ok
        end
      end)

    assert_receive {:pause, :all}
    assert QuietMode.active?(__MODULE__.Server)

    send(owner, :die)

    assert_receive {:resume, :all}
    refute QuietMode.active?(__MODULE__.Server)
  end

  test "a re-activation follows the newest activator" do
    first = spawn(fn -> forever(fn -> QuietMode.activate(__MODULE__.Server) end) end)
    assert_receive {:pause, :all}

    assert :ok = QuietMode.activate(__MODULE__.Server)
    Process.exit(first, :kill)

    refute_receive {:resume, :all}, 50
    assert QuietMode.active?(__MODULE__.Server)
  end

  test "closing another player only releases its own claim on background work" do
    server = __MODULE__.Server
    assert :ok = QuietMode.activate(server)
    assert_receive {:pause, :all}
    assert :ok = Task.async(fn -> QuietMode.deactivate(server) end) |> Task.await()
    assert QuietMode.active?(server)

    second = Task.async(fn -> QuietMode.activate(server) end)
    assert Task.await(second) == :ok
    refute_receive {:resume, :all}, 50
    assert QuietMode.active?(server)

    assert :ok = QuietMode.deactivate(server)
    assert_receive {:resume, :all}
    refute QuietMode.active?(server)
  end

  test "the Oban controller pauses and resumes after a player exits without a sandbox owner" do
    server = __MODULE__.RealControllerServer

    start_supervised!(
      Supervisor.child_spec(
        {QuietMode, name: server, controller: QuietMode.ObanController, scope: :all},
        id: server
      )
    )

    :ok = Oban.Notifier.listen(:signal)
    caller = self()

    {owner, ref} =
      spawn_monitor(fn ->
        send(caller, {:activated, QuietMode.activate(server)})

        receive do
          :close -> :ok
        end
      end)

    on_exit(fn -> send(owner, :close) end)

    assert_receive {:activated, :ok}
    assert_receive {:notification, :signal, %{"action" => "pause", "queue" => "*"}}
    assert QuietMode.active?(server)

    send(owner, :close)

    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    assert_receive {:notification, :signal, %{"action" => "resume", "queue" => "*"}}
    refute QuietMode.active?(server)
  end

  defp forever(fun) do
    fun.()
    Process.sleep(:infinity)
  end
end
