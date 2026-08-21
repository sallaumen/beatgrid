defmodule Beatgrid.Library.SourceBrowser do
  @moduledoc """
  Directory listing behind the import modal's folder browser: subdirectories plus
  import-candidate files, by extension only — probing belongs to the preview
  (`Library.preview_import/2`), never to a listing that may hold hundreds of
  entries. Single-user local app: the server browses the DJ's own disk, the same
  trust the pasted-path field already carries.
  """

  alias Beatgrid.Library.FileInfo

  @type entry :: %{name: String.t(), path: String.t()}
  @type listing :: %{
          dir: String.t(),
          parent: String.t() | nil,
          dirs: [entry()],
          files: [entry()]
        }

  @doc """
  Lists `dir` (after `Path.expand`): visible subdirectories and candidate files,
  each case-insensitively sorted. `parent` is `nil` at the filesystem root.
  """
  @spec list(String.t()) :: {:ok, listing()} | {:error, :not_a_dir | :unreadable}
  def list(dir) do
    dir = Path.expand(dir)

    if File.dir?(dir), do: read(dir), else: {:error, :not_a_dir}
  end

  @doc "Where browsing starts: `~/Downloads` (where downloads land), else home."
  @spec start_dir() :: String.t()
  def start_dir do
    downloads = Path.expand("~/Downloads")
    if File.dir?(downloads), do: downloads, else: Path.expand("~")
  end

  defp read(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        {dirs, files} =
          entries
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.sort_by(&String.downcase/1)
          |> Enum.map(&%{name: &1, path: Path.join(dir, &1)})
          |> Enum.split_with(&File.dir?(&1.path))

        {:ok,
         %{
           dir: dir,
           parent: parent_of(dir),
           dirs: dirs,
           files: Enum.filter(files, &FileInfo.candidate?(&1.path))
         }}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp parent_of("/"), do: nil
  defp parent_of(dir), do: Path.dirname(dir)
end
