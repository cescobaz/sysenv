defmodule Mix.Tasks.SysenvTest do
  # Not async: the task reads `config/*.exs` of the current directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "config"))

    File.write!(Path.join(tmp_dir, "config/runtime.exs"), """
    import Config

    config :my_app, region: Sysenv.get_system_env!("S3_REGION", dev: "fra1")
    """)

    :ok
  end

  test "prints the table of the variables", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        File.cd!(tmp_dir, fn -> assert {:ok, [_region]} = Mix.Tasks.Sysenv.run([]) end)
      end)

    assert output =~ "VARIABLE"
    assert output =~ ~r/S3_REGION\s+"fra1"\s+required\s+required\s+config\/runtime.exs:3/
  end

  test "writes the env file, and replaces it only with --force", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      capture_io(fn ->
        assert {:ok, "dev.env"} = Mix.Tasks.Sysenv.run(["--generate", "dev"])
      end)

      assert File.read!("dev.env") == "S3_REGION=fra1\n"

      assert_raise Mix.Error, ~r/already exists/, fn ->
        Mix.Tasks.Sysenv.run(["--generate", "dev"])
      end

      capture_io(fn ->
        assert {:ok, "dev.env"} = Mix.Tasks.Sysenv.run(["--generate", "dev", "--force"])
      end)
    end)
  end

  test "raises for a config env that does not exist", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert_raise Mix.Error, ~r/The config env must be one of dev, test, prod/, fn ->
        Mix.Tasks.Sysenv.run(["--generate", "staging"])
      end
    end)
  end
end
