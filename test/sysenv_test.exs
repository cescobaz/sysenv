defmodule SysenvTest do
  use ExUnit.Case, async: true

  describe "fetch_env/2" do
    setup context do
      key = :"env_fetch_env_test_#{context.line}"
      on_exit(fn -> Application.delete_env(:sysenv_test, key) end)
      %{key: key}
    end

    test "returns the value of a set key", %{key: key} do
      Application.put_env(:sysenv_test, key, "v5 MOCK value")

      assert Sysenv.fetch_env(:sysenv_test, key) == {:ok, "v5 MOCK value"}
    end

    test "returns a value that is not a string", %{key: key} do
      Application.put_env(:sysenv_test, key, enabled: false)

      assert Sysenv.fetch_env(:sysenv_test, key) == {:ok, [enabled: false]}
    end

    test "returns false, which is a value", %{key: key} do
      Application.put_env(:sysenv_test, key, false)

      assert Sysenv.fetch_env(:sysenv_test, key) == {:ok, false}
    end

    test "returns not set for a missing key", %{key: key} do
      assert Sysenv.fetch_env(:sysenv_test, key) == {:error, :not_set}
    end

    test "returns not set for a nil value or an empty string", %{key: key} do
      Application.put_env(:sysenv_test, key, nil)
      assert Sysenv.fetch_env(:sysenv_test, key) == {:error, :not_set}

      Application.put_env(:sysenv_test, key, "")
      assert Sysenv.fetch_env(:sysenv_test, key) == {:error, :not_set}
    end

    test "returns the value of a key nested in keyword lists", %{key: key} do
      Application.put_env(:sysenv_test, key, service: [api_key: "v5 MOCK key"])

      assert Sysenv.fetch_env(:sysenv_test, [key, :service, :api_key]) == {:ok, "v5 MOCK key"}
    end

    test "returns not set for a missing parent or nested key", %{key: key} do
      assert Sysenv.fetch_env(:sysenv_test, [key, :api_key]) == {:error, :not_set}

      Application.put_env(:sysenv_test, key, other: "v5 MOCK other")
      assert Sysenv.fetch_env(:sysenv_test, [key, :api_key]) == {:error, :not_set}
    end

    test "returns not set when the parent is not a keyword list", %{key: key} do
      Application.put_env(:sysenv_test, key, "v5 MOCK value")
      assert Sysenv.fetch_env(:sysenv_test, [key, :api_key]) == {:error, :not_set}

      Application.put_env(:sysenv_test, key, [{:api_key, "v5 MOCK key"}, :invalid])
      assert Sysenv.fetch_env(:sysenv_test, [key, :api_key]) == {:error, :not_set}
    end

    test "returns not set for a nil or empty nested value", %{key: key} do
      Application.put_env(:sysenv_test, key, api_key: nil, secret: "")

      assert Sysenv.fetch_env(:sysenv_test, [key, :api_key]) == {:error, :not_set}
      assert Sysenv.fetch_env(:sysenv_test, [key, :secret]) == {:error, :not_set}
    end

    test "returns not set for an app or a key that is not an atom" do
      assert Sysenv.fetch_env(:sysenv_test, "api_key") == {:error, :not_set}
      assert Sysenv.fetch_env("sysenv_test", :api_key) == {:error, :not_set}
      assert Sysenv.fetch_env(:sysenv_test, []) == {:error, :not_set}
    end
  end

  describe "get_system_env!/3" do
    @describetag :tmp_dir

    setup context do
      name = "SYSENV_TEST_#{context.line}"
      on_exit(fn -> System.delete_env(name) end)
      %{name: name}
    end

    # Evaluates a config file that sets `:value` to
    # `get_system_env!(name, defaults, opts)`.
    defp read_config(tmp_dir, name, defaults, env, opts \\ []) do
      path = Path.join(tmp_dir, "runtime.exs")

      File.write!(path, """
      import Config

      config :sysenv_config_test,
        value: Sysenv.get_system_env!(#{inspect(name)}, #{inspect(defaults)}, #{inspect(opts)})
      """)

      path
      |> Config.Reader.read!(env: env)
      |> get_in([:sysenv_config_test, :value])
    end

    test "returns the value of a set variable over the default", %{name: name, tmp_dir: dir} do
      System.put_env(name, "v5 MOCK value")

      assert read_config(dir, name, [dev: "v5 MOCK default"], :dev) == "v5 MOCK value"
    end

    test "returns the default of the config env for a missing variable", %{
      name: name,
      tmp_dir: dir
    } do
      defaults = [dev: "v5 MOCK dev", prod: "v5 MOCK prod"]

      assert read_config(dir, name, defaults, :dev) == "v5 MOCK dev"
      assert read_config(dir, name, defaults, :prod) == "v5 MOCK prod"
    end

    test "returns the default for an empty variable", %{name: name, tmp_dir: dir} do
      System.put_env(name, "")

      assert read_config(dir, name, [dev: "v5 MOCK default"], :dev) == "v5 MOCK default"
    end

    test "returns a nil default", %{name: name, tmp_dir: dir} do
      assert read_config(dir, name, [dev: nil], :dev) == nil
    end

    test "raises when the config env has no default", %{name: name, tmp_dir: dir} do
      assert_raise RuntimeError, "environment variable #{name} is missing (test)", fn ->
        read_config(dir, name, [dev: "v5 MOCK dev"], :test)
      end
    end

    test "casts a set variable and a string default to an integer", %{name: name, tmp_dir: dir} do
      assert read_config(dir, name, [dev: "30"], :dev, cast: :integer) == 30

      System.put_env(name, "-7")
      assert read_config(dir, name, [dev: "30"], :dev, cast: :integer) == -7
    end

    test "casts a set variable and a string default to an integer that is zero or more", %{
      name: name,
      tmp_dir: dir
    } do
      assert read_config(dir, name, [dev: "30"], :dev, cast: :non_neg_integer) == 30

      System.put_env(name, "0")
      assert read_config(dir, name, [dev: "30"], :dev, cast: :non_neg_integer) == 0

      Enum.each(["-7", "30 days"], fn value ->
        System.put_env(name, value)

        assert_raise RuntimeError,
                     "environment variable #{name} must be an integer that is zero or more, " <>
                       "got: #{inspect(value)}",
                     fn -> read_config(dir, name, [], :dev, cast: :non_neg_integer) end
      end)
    end

    test "casts a set variable and a string default to an integer that is more than zero", %{
      name: name,
      tmp_dir: dir
    } do
      assert read_config(dir, name, [dev: "30"], :dev, cast: :pos_integer) == 30

      System.put_env(name, "1")
      assert read_config(dir, name, [dev: "30"], :dev, cast: :pos_integer) == 1

      Enum.each(["0", "-7", "30 days"], fn value ->
        System.put_env(name, value)

        assert_raise RuntimeError,
                     "environment variable #{name} must be an integer that is more than zero, " <>
                       "got: #{inspect(value)}",
                     fn -> read_config(dir, name, [], :dev, cast: :pos_integer) end
      end)
    end

    test "casts a set variable and a string default to a boolean", %{name: name, tmp_dir: dir} do
      assert read_config(dir, name, [dev: "false"], :dev, cast: :boolean) == false

      Enum.each([{"true", true}, {"1", true}, {"false", false}, {"0", false}], fn {value, cast} ->
        System.put_env(name, value)
        assert read_config(dir, name, [dev: "false"], :dev, cast: :boolean) == cast
      end)
    end

    test "returns a default that is not a string without casting it", %{
      name: name,
      tmp_dir: dir
    } do
      assert read_config(dir, name, [dev: nil], :dev, cast: :integer) == nil
    end

    test "raises when the value cannot be cast", %{name: name, tmp_dir: dir} do
      System.put_env(name, "30 days")

      assert_raise RuntimeError,
                   "environment variable #{name} must be an integer, got: \"30 days\"",
                   fn -> read_config(dir, name, [], :dev, cast: :integer) end

      assert_raise RuntimeError,
                   "environment variable #{name} must be true, false, 1 or 0, got: \"30 days\"",
                   fn -> read_config(dir, name, [], :dev, cast: :boolean) end
    end

    test "raises outside of a config file", %{name: name} do
      assert_raise RuntimeError, ~r/could not set configuration via Config/, fn ->
        Sysenv.get_system_env!(name, dev: "v5 MOCK dev", test: "v5 MOCK test")
      end
    end

    test "raises on an unknown cast", %{name: name, tmp_dir: dir} do
      System.put_env(name, "v5 MOCK value")

      assert_raise ArgumentError, fn -> read_config(dir, name, [], :dev, cast: :float) end
    end
  end
end
