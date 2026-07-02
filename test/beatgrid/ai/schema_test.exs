defmodule Beatgrid.AI.SchemaTest do
  use ExUnit.Case, async: true

  alias Beatgrid.AI.Schema

  test "object/1 closes the shape and requires every property" do
    assert %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["a", "b"]
           } = Schema.object(%{"a" => Schema.string(), "b" => Schema.integer()})
  end

  test "object/2 narrows the required list" do
    schema = Schema.object(%{"a" => Schema.string(), "b" => Schema.integer()}, ["a"])
    assert schema["required"] == ["a"]
  end

  test "list_of/2 wraps closed items in a single required envelope key" do
    schema = Schema.list_of("items", %{"x" => Schema.string()})

    assert schema["required"] == ["items"]

    assert %{"type" => "array", "items" => %{"required" => ["x"]}} =
             schema["properties"]["items"]
  end

  test "string/1 constrains to an enum" do
    assert %{"type" => "string", "enum" => ["a", "b"]} = Schema.string(enum: ["a", "b"])
  end

  test "nullable/1 widens the scalar type" do
    assert %{"type" => ["string", "null"]} = Schema.nullable(Schema.string())
    assert %{"type" => ["integer", "null"]} = Schema.nullable(Schema.integer())
  end
end
