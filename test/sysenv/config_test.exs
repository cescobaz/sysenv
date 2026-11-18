defmodule Sysenv.ConfigTest do
  use ExUnit.Case, async: true

  alias Sysenv.Config

  @moduletag :tmp_dir

  defp write_config(tmp_dir, source) do
    path = Path.join(tmp_dir, "runtime.exs")
    File.write!(path, source)
    path
  end

  describe "list_system_envs/1" do
    test "lists the default of each config env of a get_system_env! read", %{tmp_dir: tmp_dir} do
      path =
        write_config(tmp_dir, """
        import Config
        alias Sysenv, as: Env

        config :my_app,
          region: Env.get_system_env!("S3_REGION", dev: "fra1", prod: nil),
          secret: Env.get_system_env!("SECRET")
        """)

      assert {:ok, [region, secret]} = Config.list_system_envs([path])

      assert region == %{
               name: "S3_REGION",
               file: path,
               line: 5,
               read: :get_system_env!,
               inside: [],
               defaults: %{dev: ~s("fra1"), test: "required", prod: "nil"},
               values: %{dev: "fra1", test: nil, prod: nil}
             }

      assert secret.name == "SECRET"
      assert secret.defaults == %{dev: "required", test: "required", prod: "required"}
    end

    test "lists the reads through System", %{tmp_dir: tmp_dir} do
      path =
        write_config(tmp_dir, """
        a = System.get_env("A")
        b = System.get_env("B", "b")
        c = System.fetch_env!("C")
        d = "x\#{System.get_env("D")}"
        """)

      assert {:ok, system_envs} = Config.list_system_envs([path])

      assert Enum.map(system_envs, &{&1.name, &1.read, &1.defaults.prod, &1.values.prod}) == [
               {"A", :get_env, "-", nil},
               {"B", :get_env, ~s("b"), "b"},
               {"C", :fetch_env!, "required", nil},
               {"D", :get_env, "-", nil}
             ]
    end

    test "names the ifs a read sits in", %{tmp_dir: tmp_dir} do
      path =
        write_config(tmp_dir, """
        if config_env() == :prod do
          if System.get_env("IPV6") do
            Env.get_system_env!("HOST", prod: "example.com")
          end
        else
          Env.get_system_env!("OTHER")
        end
        """)

      assert {:ok, system_envs} = Config.list_system_envs([path])

      assert Enum.map(system_envs, &{&1.name, &1.inside}) == [
               {"IPV6", ["config_env() == :prod"]},
               {"HOST", ["config_env() == :prod", ~s[System.get_env("IPV6")]]},
               {"OTHER", ["not (config_env() == :prod)"]}
             ]
    end

    test "returns an error for a file it cannot read", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.exs")

      assert Config.list_system_envs([path]) == {:error, {:read_error, path, :enoent}}
    end

    test "returns an error for a file it cannot parse", %{tmp_dir: tmp_dir} do
      path = write_config(tmp_dir, "config :my_app, [")

      assert {:error, {:parse_error, ^path, _reason}} = Config.list_system_envs([path])
    end
  end

  describe "build_env_file/3" do
    setup %{tmp_dir: tmp_dir} do
      path =
        write_config(tmp_dir, """
        region = Env.get_system_env!("S3_REGION", dev: "fra1")
        scopes = Env.get_system_env!("SCOPES", dev: "a b", prod: nil)
        again = Env.get_system_env!("S3_REGION", dev: "fra1")

        if System.get_env("PHX_SERVER") do
          config :my_app, server: true
        end

        if config_env() == :prod do
          Env.get_system_env!("PORT", prod: "4000")
        else
          Env.get_system_env!("DEBUG", dev: "it's on")
        end
        """)

      {:ok, system_envs} = Config.list_system_envs([path])
      %{system_envs: system_envs}
    end

    test "writes the string default of the config env, each variable once", %{
      system_envs: system_envs
    } do
      assert Config.build_env_file(system_envs, "dev") ==
               {:ok,
                """
                S3_REGION=fra1
                SCOPES='a b'
                # PHX_SERVER=
                DEBUG='it'\\''s on'
                """}
    end

    test "leaves a variable without a string default empty, and out when another config env reads it",
         %{system_envs: system_envs} do
      assert Config.build_env_file(system_envs, "prod") ==
               {:ok,
                """
                S3_REGION=
                SCOPES=
                # PHX_SERVER=
                PORT=4000
                """}
    end

    test "writes the values as they are for docker", %{system_envs: system_envs} do
      assert Config.build_env_file(system_envs, "dev", format: :docker) ==
               {:ok,
                """
                S3_REGION=fra1
                SCOPES=a b
                # PHX_SERVER=
                DEBUG=it's on
                """}
    end

    test "returns an error for a format that does not exist", %{system_envs: system_envs} do
      assert Config.build_env_file(system_envs, "dev", format: :fish) ==
               {:error, :unsupported_format}
    end

    test "returns an error for a config env that does not exist", %{system_envs: system_envs} do
      assert Config.build_env_file(system_envs, "staging") == {:error, :unsupported_config_env}
      assert Config.build_env_file(:invalid, "dev") == {:error, :invalid_argument}
      assert Config.list_system_envs(:invalid) == {:error, :invalid_argument}
      assert Config.list_system_envs([:invalid]) == {:error, :invalid_argument}
    end
  end
end
