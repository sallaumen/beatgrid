defmodule Beatgrid.Workers.ScanWorker do
  @moduledoc "Scans the library (or a given root) in the background."
  use Oban.Worker, queue: :scan, max_attempts: 3, unique: [period: 30]

  alias Beatgrid.Library
  alias Beatgrid.Library.Scanner

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    root = Map.get(args, "root") || Library.library_root()
    mark_missing = Map.get(args, "mark_missing", true)

    {:ok, _summary} = Scanner.scan(root, mark_missing: mark_missing)
    :ok
  end

  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(opts \\ []) do
    %{
      "root" => opts[:root] || Library.library_root(),
      "mark_missing" => Keyword.get(opts, :mark_missing, true)
    }
    |> new()
    |> Oban.insert()
  end
end
