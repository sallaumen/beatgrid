defmodule Beatgrid.YouTube.Preview do
  @moduledoc "Read-only video selection. Confirmation queues exactly the displayed video IDs."
  alias Beatgrid.{Error, Repo}
  alias Beatgrid.Workers.DownloadWorker
  alias Beatgrid.YouTube.{Downloader, Link}

  @downloader Application.compile_env!(:beatgrid, [Downloader, :adapter])

  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(input) do
    input
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Link.parse/1)
    |> Enum.uniq()
    |> collect()
  end

  defp collect([]), do: invalid_link()

  defp collect(sources) do
    if :invalid in sources do
      invalid_link()
    else
      Enum.reduce_while(sources, {:ok, []}, &collect_source/2)
      |> flatten_groups()
    end
  end

  defp collect_source(source, {:ok, groups}) do
    case list_source(source) do
      {:ok, rows} -> {:cont, {:ok, [rows | groups]}}
      error -> {:halt, error}
    end
  end

  defp flatten_groups({:ok, groups}),
    do: {:ok, groups |> Enum.reverse() |> List.flatten() |> Enum.uniq_by(& &1.id)}

  defp flatten_groups(error), do: error

  defp invalid_link do
    {:error, Error.new(:invalid_link, "Cole um link de vídeo ou playlist do YouTube.")}
  end

  @spec search(String.t()) :: {:ok, [map()]} | {:error, term()}
  def search(query), do: list_source({:search, query}, "ytsearch3:" <> query)

  defp list_source(source), do: list_source(source, Link.url(source))

  defp list_source(source, url) do
    with {:ok, entries} <- @downloader.list_entries(url) do
      rows =
        for {entry, index} <- Enum.with_index(entries, 1),
            Link.video(entry.id) != :invalid,
            match_source?(source, entry.id) do
          %{
            id: entry.id,
            title: entry.title,
            url: Link.url({:video, entry.id}),
            playlist_url: if(elem(source, 0) == :playlist, do: url),
            playlist_title: if(elem(source, 0) == :playlist, do: entry[:playlist_title]),
            playlist_index: if(elem(source, 0) == :playlist, do: index)
          }
        end

      if rows == [],
        do: {:error, Error.new(:no_entries, "Nenhuma faixa disponível neste link.")},
        else: {:ok, rows}
    end
  end

  defp match_source?({:video, expected}, id), do: id == expected
  defp match_source?(_, _), do: true

  @spec confirm([map()], [String.t()], String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def confirm(rows, ids, recommendation_id) do
    selected = MapSet.new(ids)
    entries = Enum.filter(rows, &MapSet.member?(selected, &1.id))

    if entries == [] do
      {:error, :empty_selection}
    else
      batch = Uniq.UUID.uuid7()

      Repo.transact(fn ->
        Enum.reduce_while(entries, {:ok, batch}, &enqueue_entry(&1, &2, recommendation_id))
      end)
    end
  end

  defp enqueue_entry(entry, {:ok, batch}, recommendation_id) do
    case DownloadWorker.enqueue(entry.url,
           batch_id: batch,
           recommendation_id: recommendation_id,
           video_id: entry.id,
           title: entry.title,
           playlist_index: entry.playlist_index,
           playlist_url: entry.playlist_url,
           playlist_title: entry.playlist_title
         ) do
      {:ok, _job} -> {:cont, {:ok, batch}}
      error -> {:halt, error}
    end
  end
end
