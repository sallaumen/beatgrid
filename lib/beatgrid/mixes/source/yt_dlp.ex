defmodule Beatgrid.Mixes.Source.YtDlp do
  @moduledoc """
  `Mixes.Source` adapter backed by yt-dlp (SoundCloud supported natively). Downloads
  the single audio track to mp3 and captures its metadata. The description is printed
  JSON-encoded (`%(description)j`) so multi-line text stays on one line for parsing.

  Same hardening as the other CLI adapters: stdin from `/dev/null` and a generous
  timeout (a 1h set is a long download).
  """
  @behaviour Beatgrid.Mixes.Source

  @sep "\t"
  @default_timeout_ms 900_000
  @error_excerpt 1_000

  @impl true
  def fetch(url, dest_dir) do
    File.mkdir_p!(dest_dir)
    template = Path.join(dest_dir, "%(id)s.%(ext)s")

    cli_args = [
      "-x",
      "--audio-format",
      "mp3",
      "--no-overwrites",
      "--no-playlist",
      "--print",
      "after_move:%(id)s#{@sep}%(title)s#{@sep}%(uploader)s#{@sep}%(duration)s#{@sep}%(description)j#{@sep}%(chapters)j",
      "-o",
      template,
      url
    ]

    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    case run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: true) end, timeout()) do
      {:ok, {out, 0}} -> parse_meta(out, dest_dir)
      {:ok, {out, code}} -> {:error, {:yt_dlp_exit, code, String.slice(out, 0, @error_excerpt)}}
      {:exit, reason} -> {:error, {:yt_dlp_exception, inspect(reason)}}
      nil -> {:error, :timeout}
    end
  end

  @doc "Parses yt-dlp's tab-separated metadata line into a `Source.meta`. Public for tests."
  @spec parse_meta(String.t(), String.t()) ::
          {:ok, Beatgrid.Mixes.Source.meta()} | {:error, :no_metadata}
  def parse_meta(output, dest_dir) do
    line = output |> String.split("\n", trim: true) |> List.last()

    case line && String.split(line, @sep) do
      [id, title, uploader, duration, description, chapters] ->
        {:ok,
         %{
           audio_path: Path.join(dest_dir, id <> ".mp3"),
           title: nil_if_blank(title),
           dj: nil_if_blank(uploader),
           duration_ms: duration_ms(duration),
           description: decode_description(description),
           chapters: decode_chapters(chapters)
         }}

      _ ->
        {:error, :no_metadata}
    end
  end

  defp duration_ms(s) do
    case Float.parse(String.trim(s)) do
      {secs, _rest} -> round(secs * 1000)
      :error -> nil
    end
  end

  defp decode_description(json) do
    case Jason.decode(json) do
      {:ok, text} when is_binary(text) -> text
      _ -> ""
    end
  end

  defp decode_chapters(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        for %{"start_time" => s} = c <- list, is_number(s) do
          %{start_ms: round(s * 1000), title: nil_if_blank(c["title"]) || ""}
        end

      _ ->
        []
    end
  end

  defp nil_if_blank(s), do: if(String.trim(s) in ["", "NA"], do: nil, else: s)

  defp run(fun, timeout) do
    task = Task.async(fun)
    Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)
  end

  defp executable, do: config()[:executable] || "yt-dlp"
  defp timeout, do: config()[:timeout_ms] || @default_timeout_ms
  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
end
