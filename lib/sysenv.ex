defmodule Sysenv do
  @moduledoc """
  Reads the configuration of an application without silent holes.

    * `get_system_env!/3` reads an OS environment variable in a config file,
      with one default per config env, and refuses to boot when there is
      none.
    * `fetch_env/2` reads the application environment and answers
      `{:error, :not_set}` where `Application` answers `:error`, `nil` or
      `""`.
    * `mix sysenv` prints every OS environment variable the config files
      read, and writes an env file out of them.
  """

  require Config

  @doc """
  Reads `key` of `app` from the application environment, like
  `Application.fetch_env/2`.

  `key` is an atom, or the path to a key nested in keyword lists: the first
  key is read from the application environment, each next one from the
  keyword list found so far.

  Returns `{:ok, value}`, or `{:error, :not_set}` when the key, or any key
  on its path, is missing, `nil` or `""`.

      Sysenv.fetch_env(:my_app, :stripe_secret_key)
      Sysenv.fetch_env(:my_app, [:firecrawl, :api_key])
  """
  def fetch_env(app, key) do
    case read_env(app, key) do
      {:ok, value} when value not in [nil, ""] -> {:ok, value}
      _not_set -> {:error, :not_set}
    end
  end

  defp read_env(app, key) when is_atom(app) and is_atom(key) do
    Application.fetch_env(app, key)
  end

  defp read_env(app, [key | path]) when is_atom(app) and is_atom(key) do
    with {:ok, value} <- Application.fetch_env(app, key) do
      read_path(value, path)
    end
  end

  defp read_env(_app, _key), do: :error

  defp read_path(value, []), do: {:ok, value}

  defp read_path(value, [key | path]) when is_list(value) and is_atom(key) do
    if Keyword.keyword?(value) do
      with {:ok, child} <- Keyword.fetch(value, key) do
        read_path(child, path)
      end
    else
      :error
    end
  end

  defp read_path(_value, _path), do: :error

  @doc """
  Reads the OS environment variable `name` in a config file.

  When `name` is not set, or set to `""`, returns the default that
  `defaults` holds for the `config_env/0` of the file (`:dev`, `:test` or
  `:prod`); a default can be any term, `nil` included. Raises when there is
  none: the system must not boot without its configuration.

  The config env is the one of the config file being evaluated: call it in
  a config file, or in a function a config file calls. Anywhere else it
  raises, as `Config.config_env/0` does.

  `opts` takes `:cast`, the type the string is turned into, for the value of
  the variable and for a string default alike; a default that is not a
  string is returned as it is. Raises when the string is not of that type.

    * `:integer` - a whole number, such as `"30"` or `"-1"`
    * `:non_neg_integer` - a whole number that is zero or more, such as `"30"` or `"0"`
    * `:pos_integer` - a whole number that is more than zero, such as `"30"`
    * `:boolean` - `"true"` or `"1"` for `true`, `"false"` or `"0"` for `false`

  A dependency is compiled before `config/runtime.exs` is evaluated, but not
  before `config/config.exs` and the files it imports: use it in
  `config/runtime.exs`.

      import Config

      config :my_app,
        s3_region: Sysenv.get_system_env!("S3_REGION", dev: "fra1", prod: "fra1"),
        pool_size: Sysenv.get_system_env!("POOL_SIZE", [prod: "30"], cast: :integer)
  """
  def get_system_env!(name, defaults \\ [], opts \\ [])
      when is_binary(name) and is_list(defaults) and is_list(opts) do
    config_env = Config.config_env()

    value =
      case System.get_env(name) do
        value when value not in [nil, ""] ->
          value

        _ ->
          case Keyword.fetch(defaults, config_env) do
            {:ok, default} -> default
            :error -> raise "environment variable #{name} is missing (#{config_env})"
          end
      end

    case Keyword.fetch(opts, :cast) do
      {:ok, type} when is_binary(value) -> cast_system_env!(name, value, type)
      _ -> value
    end
  end

  defp cast_system_env!(name, value, :integer) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> raise "environment variable #{name} must be an integer, got: #{inspect(value)}"
    end
  end

  defp cast_system_env!(name, value, :non_neg_integer) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 ->
        integer

      _ ->
        raise "environment variable #{name} must be an integer that is zero or more, " <>
                "got: #{inspect(value)}"
    end
  end

  defp cast_system_env!(name, value, :pos_integer) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 ->
        integer

      _ ->
        raise "environment variable #{name} must be an integer that is more than zero, " <>
                "got: #{inspect(value)}"
    end
  end

  defp cast_system_env!(_name, value, :boolean) when value in ["true", "1"], do: true
  defp cast_system_env!(_name, value, :boolean) when value in ["false", "0"], do: false

  defp cast_system_env!(name, value, :boolean) do
    raise "environment variable #{name} must be true, false, 1 or 0, got: #{inspect(value)}"
  end

  defp cast_system_env!(name, _value, type) do
    raise ArgumentError, "unknown cast #{inspect(type)} for environment variable #{name}"
  end
end
