defmodule Beatgrid.DataCase do
  @moduledoc """
  Setup for tests that need the data layer.

  Options:

    * `async: true`     — private sandbox connection (the default you want)
    * `oban: true`      — brings in `perform_job/2`, `assert_enqueued/1`, …
    * `properties: true` — brings in StreamData's `property` / `check all`

  Imports the Factory and Mox into every case; `verify_on_exit!` runs after each test.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using opts do
    [
      if(Keyword.get(opts, :properties, false), do: quote(do: use(ExUnitProperties))),
      if(Keyword.get(opts, :oban, false), do: quote(do: use(Oban.Testing, repo: Beatgrid.Repo))),
      quote do
        alias Beatgrid.Repo

        import Ecto
        import Ecto.Changeset
        import Ecto.Query
        import Mox
        import Beatgrid.Factory
        import Beatgrid.DataCase
      end
    ]
  end

  setup tags do
    Beatgrid.DataCase.setup_sandbox(tags)
    Mox.verify_on_exit!(tags)
    :ok
  end

  @doc "Sets up the SQL sandbox based on the test tags."
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Beatgrid.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  Transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
