defmodule Beatgrid.Soundcharts.Response do
  @moduledoc """
  A normalized Soundcharts API response: the parsed `data` plus the transport
  metadata the budget guard needs (`quota_remaining` from the `x-quota-remaining`
  header, and the HTTP `status`).
  """
  @type t :: %__MODULE__{data: any(), quota_remaining: integer() | nil, status: integer() | nil}

  defstruct [:data, :quota_remaining, :status]
end
