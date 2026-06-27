defmodule Beatgrid.Soundcharts.Response do
  @moduledoc """
  A normalized Soundcharts API response: the parsed `data` plus the transport
  metadata the budget guard needs (`quota_remaining` from the `x-quota-remaining`
  header, the HTTP `status`, and the `account` the call was billed to).
  """
  @type t :: %__MODULE__{
          data: any(),
          quota_remaining: integer() | nil,
          status: integer() | nil,
          account: String.t() | nil
        }

  defstruct [:data, :quota_remaining, :status, :account]
end
