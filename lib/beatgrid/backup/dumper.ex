defmodule Beatgrid.Backup.Dumper do
  @moduledoc "Port for producing one database dump file from the repo's connection config."

  @callback dump(repo_config :: keyword(), dest :: String.t()) :: :ok | {:error, term()}
end
