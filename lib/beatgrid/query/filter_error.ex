defmodule Beatgrid.Query.FilterError do
  @moduledoc """
  Raised when a query module receives an option it doesn't support. A typo in a
  caller then fails loudly with the offending key/value instead of a bare
  `FunctionClauseError` deep inside the reducer.
  """
  defexception [:message, :field, :value]

  @impl true
  def exception(opts) do
    field = Keyword.fetch!(opts, :field)
    value = Keyword.get(opts, :value)

    %__MODULE__{
      message: "unsupported query option #{inspect(field)} (value: #{inspect(value)})",
      field: field,
      value: value
    }
  end
end
