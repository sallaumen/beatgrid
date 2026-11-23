defmodule Beatgrid.YouTube.Downloader do
  @moduledoc """
  Lists video metadata for review and downloads one confirmed video at a time.
  """
  @type item :: %{
          path: String.t(),
          title: String.t(),
          url: String.t(),
          views: integer() | nil,
          upload_date: String.t() | nil
        }
  @type entry :: %{
          id: String.t(),
          title: String.t(),
          url: String.t(),
          playlist_title: String.t() | nil
        }

  @callback download(url :: String.t(), dest_dir :: String.t()) ::
              {:ok, [item()]} | {:error, term()}

  @callback list_entries(url :: String.t()) :: {:ok, [entry()]} | {:error, term()}
end
