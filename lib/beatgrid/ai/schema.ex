defmodule Beatgrid.AI.Schema do
  @moduledoc """
  Builders for the strict JSON Schemas that constrain the AI port's output.
  Every object is closed (`additionalProperties: false`) and fully required by
  default — the model either fills the declared shape or the call fails, never
  a partially-parsed result. The use-case AI modules declare WHAT shape they
  need; the JSON-Schema encoding lives here.
  """

  @type t :: map()

  @doc "A closed object. All properties are required unless `required` narrows it."
  @spec object(%{String.t() => t()}, [String.t()] | nil) :: t()
  def object(properties, required \\ nil) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required || Enum.sort(Map.keys(properties))
    }
  end

  @doc "A closed single-key envelope holding an array of closed `item_properties` objects."
  @spec list_of(String.t(), %{String.t() => t()}, [String.t()] | nil) :: t()
  def list_of(key, item_properties, required \\ nil) do
    object(%{key => array(object(item_properties, required))})
  end

  @doc "An array of `item` schemas."
  @spec array(t()) :: t()
  def array(item), do: %{"type" => "array", "items" => item}

  @spec string() :: t()
  def string, do: %{"type" => "string"}

  @spec string(enum: [String.t()]) :: t()
  def string(enum: values), do: %{"type" => "string", "enum" => values}

  @spec integer() :: t()
  def integer, do: %{"type" => "integer"}

  @spec number() :: t()
  def number, do: %{"type" => "number"}

  @spec boolean() :: t()
  def boolean, do: %{"type" => "boolean"}

  @doc "A nullable variant of a scalar schema."
  @spec nullable(t()) :: t()
  def nullable(%{"type" => type} = schema), do: %{schema | "type" => [type, "null"]}
end
