defmodule Beatgrid.AI.ClaudeCliTest do
  use ExUnit.Case, async: true

  alias Beatgrid.AI.ClaudeCli

  describe "parse_output/1" do
    test "extracts structured_output from a successful envelope" do
      envelope =
        ~s({"type":"result","is_error":false,"result":"human text","structured_output":{"classifications":[{"index":1,"folder":"mpb","confidence":0.9,"rationale":"x"}]}})

      assert {:ok, %{"classifications" => [%{"folder" => "mpb"}]}} =
               ClaudeCli.parse_output(envelope)
    end

    test "errors when the CLI reports an error" do
      assert {:error, _} = ClaudeCli.parse_output(~s({"is_error":true,"result":"refused"}))
    end

    test "errors when there is no structured_output" do
      assert {:error, _} = ClaudeCli.parse_output(~s({"is_error":false,"result":"just text"}))
    end

    test "errors on invalid JSON" do
      assert {:error, _} = ClaudeCli.parse_output("not json at all")
    end
  end
end
