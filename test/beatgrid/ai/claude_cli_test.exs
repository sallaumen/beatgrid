defmodule Beatgrid.AI.ClaudeCliTest do
  use ExUnit.Case, async: true

  alias Beatgrid.AI.ClaudeCli

  describe "complete/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "claude_cli_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      prev = Application.get_env(:beatgrid, ClaudeCli, [])

      on_exit(fn ->
        Application.put_env(:beatgrid, ClaudeCli, prev)
        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    defp fake(dir, body, extra_cfg \\ []) do
      path = Path.join(dir, "fake_claude")
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      Application.put_env(:beatgrid, ClaudeCli, Keyword.merge([executable: path], extra_cfg))
      path
    end

    test "invokes the CLI and returns its structured output", %{dir: dir} do
      fake(dir, ~s|echo '{"is_error":false,"structured_output":{"gaps":[]}}'\n|)

      assert {:ok, %{"gaps" => []}} =
               ClaudeCli.complete("p", %{"type" => "object"}, model: "sonnet")
    end

    test "feeds the CLI an empty stdin so it can't block waiting for input", %{dir: dir} do
      marker = Path.join(dir, "stdin.bin")

      fake(
        dir,
        "cat > #{marker}\n" <> ~s|echo '{"is_error":false,"structured_output":{"ok":true}}'\n|
      )

      assert {:ok, %{"ok" => true}} = ClaudeCli.complete("p", %{})
      assert File.read!(marker) == ""
    end

    test "returns {:error, :timeout} instead of hanging forever", %{dir: dir} do
      fake(dir, "sleep 5\n", timeout_ms: 200)
      assert {:error, :timeout} = ClaudeCli.complete("p", %{})
    end
  end

  describe "build_args/3" do
    test "build_args includes prompt, schema, model and add-dir" do
      args = ClaudeCli.build_args("hi", %{"type" => "object"}, model: "sonnet", add_dir: ["/tmp/x"])
      assert "-p" in args and "hi" in args
      assert "--model" in args and "sonnet" in args
      assert "--add-dir" in args and "/tmp/x" in args
    end
  end

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
