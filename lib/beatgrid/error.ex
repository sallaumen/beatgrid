defmodule Beatgrid.Error do
  @moduledoc """
  The domain error struct (AGENTS.md principle #3): fallible operations return
  `{:error, %Beatgrid.Error{}}` at port/context boundaries where the caller
  needs to BRANCH or REPORT with context — `code` is the stable atom to match
  on, `message` reads for humans/logs, `details` carries the specifics (HTTP
  status, exit code, output excerpt…).

  Plain reason atoms stay fine for simple internal control flow, and programmer
  errors keep raising dedicated exceptions (see `Beatgrid.Query.FilterError`).
  First adopter: the Recognition port — new ports and reworked boundaries
  should return this instead of growing ad-hoc reason tuples.
  """
  defexception [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
