defmodule Beatgrid.YtDlpError do
  @moduledoc """
  Classifies a failed yt-dlp run into the domain error (`Beatgrid.Error`) the
  download workers branch on. One home for the tool's error-string knowledge,
  shared by both adapters (tracks and mixes) — the workers match on `code`,
  never on yt-dlp's prose.

  A 429 often *also* prints "Video unavailable" (the unavailability is the rate
  limit talking), so rate-limit is checked first. The permanent list is curated
  from real failures — deliberately specific phrases, so a "temporarily
  unavailable" still retries instead of being cancelled.
  """

  alias Beatgrid.Error

  # Genuinely permanent yt-dlp refusals — retrying burns every attempt for
  # nothing (76 real jobs did exactly that before "Private video" & friends
  # were listed).
  @permanent [
    "Video unavailable",
    "not available",
    "Private video",
    "no longer available",
    "removed by the uploader",
    "account associated with this video has been terminated",
    "Sign in to confirm your age"
  ]

  @doc """
  The `Beatgrid.Error` for a nonzero yt-dlp exit. `:rate_limited` keeps "429"
  in the message — the workers' `backoff/1` greps it out of Oban's persisted
  error string.
  """
  @spec from_exit(integer(), String.t()) :: Error.t()
  def from_exit(code, out) do
    details = %{exit_code: code, output: String.slice(out, -1000, 1000)}

    cond do
      out =~ "429" or out =~ "Too Many Requests" ->
        Error.new(
          :rate_limited,
          "O YouTube limitou os downloads (429). Aguarde a próxima tentativa.",
          details
        )

      out =~ "not a bot" ->
        Error.new(
          :verification_required,
          "O YouTube pediu verificação. Importe um arquivo local ou tente mais tarde.",
          details
        )

      out =~ "HTTP Error 403" ->
        Error.new(
          :download_denied,
          "O YouTube recusou o áudio (403). Confira a versão do yt-dlp e tente novamente.",
          details
        )

      Enum.any?(@permanent, &String.contains?(out, &1)) ->
        Error.new(:video_unavailable, "O vídeo está privado, restrito ou indisponível.", details)

      true ->
        Error.new(
          :yt_dlp_exit,
          "O yt-dlp encerrou com código #{code}. Consulte os detalhes da tarefa.",
          details
        )
    end
  end
end
