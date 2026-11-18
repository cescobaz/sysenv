defmodule Sysenv.Config do
  @moduledoc """
  Finds the OS environment variables that config files read, and builds an
  env file out of them.

  The files are parsed, never evaluated: the list holds the reads of every
  branch, and a variable whose name is not a string literal is not listed.
  """

  @config_envs [:dev, :test, :prod]
  @system_reads [:get_env, :fetch_env, :fetch_env!]
  @env_file_formats [:shell, :docker]

  @doc """
  Returns the config envs a variable has a default for: `:dev`, `:test` and
  `:prod`.
  """
  def config_envs, do: @config_envs

  @doc """
  Builds the content of the env file of `config_env` (`"dev"`, `"test"` or
  `"prod"`) from the `system_envs` of `list_system_envs/1`.

  The file has one `NAME=value` line for each variable that config env
  reads, in the order of the reads, a variable read more than once being
  listed once. A variable read inside an `if` on another config env
  (`if config_env() == :prod`) is left out.

  The value is the default of the variable in that config env when it is a
  string, and empty otherwise: no default, a `nil` default, or a default
  that is an expression.

  `opts[:format]` says what reads the file:

    * `:shell` (the default) - a shell, with `source`: a value holding a
      character the shell gives a meaning to (a space, a quote, `$`) is
      single quoted;
    * `:docker` - Docker, with `--env-file`: the value is written as it is,
      since Docker takes the whole line after `=` as the value, quotes
      included.

  A variable read through `System` is written as a comment (`# NAME=`):
  such a read tells a variable that is not set from an empty one, so an
  empty line would change what the config does.

  Returns `{:ok, content}`, `{:error, :unsupported_config_env}` when
  `config_env` is not a config env, `{:error, :unsupported_format}` when the
  format is not one of the two, or `{:error, :invalid_argument}` when
  `system_envs` or `opts` is not a list.
  """
  def build_env_file(system_envs, config_env, opts \\ [])

  def build_env_file(system_envs, config_env, opts) when is_list(system_envs) and is_list(opts) do
    format = Keyword.get(opts, :format, :shell)

    case Enum.find(@config_envs, &(Atom.to_string(&1) == config_env)) do
      _config_env when format not in @env_file_formats ->
        {:error, :unsupported_format}

      nil ->
        {:error, :unsupported_config_env}

      config_env ->
        lines =
          system_envs
          |> Enum.filter(&read_in_config_env?(&1, config_env))
          |> Enum.uniq_by(& &1.name)
          |> Enum.map(&env_file_line(&1, config_env, format))

        {:ok, Enum.join(lines, "\n") <> "\n"}
    end
  end

  def build_env_file(_system_envs, _config_env, _opts), do: {:error, :invalid_argument}

  defp read_in_config_env?(system_env, config_env) do
    excluding =
      ["not (config_env() == #{inspect(config_env)})"] ++
        Enum.map(@config_envs -- [config_env], &"config_env() == #{inspect(&1)}")

    not Enum.any?(system_env.inside, &(&1 in excluding))
  end

  defp env_file_line(system_env, config_env, format) do
    line = "#{system_env.name}=#{env_file_value(system_env.values[config_env], format)}"

    case system_env.read do
      :get_system_env! -> line
      _system_read -> "# " <> line
    end
  end

  defp env_file_value(nil, _format), do: ""
  defp env_file_value(value, :docker), do: value

  defp env_file_value(value, :shell) do
    if value =~ ~r{\A[\w\-.,:/@=+]*\z} do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end

  @doc """
  Lists the OS environment variables read in the config files at `paths`, in
  the order of the files and of their lines.

  A read is a call to `get_system_env!` of any module (`Sysenv`, an alias of
  it, a wrapper of your own), or to `System.get_env`, `System.fetch_env` or
  `System.fetch_env!`.

  Each one is a map with the `name` of the variable, the `file` and `line`
  of the read, the function that reads it in `read` (`:get_system_env!`,
  `:get_env`, `:fetch_env` or `:fetch_env!`), the conditions of the `if`s
  around it in `inside`, outermost first, and its `defaults`: the source of
  the default of each config env, `"required"` or `"-"`. `values` holds the
  default of each config env when it is a string, and `nil` otherwise.

  Returns `{:ok, system_envs}`, or an error naming the first file that
  failed: `{:error, {:read_error, path, posix}}` when it cannot be read
  (`posix` as `File.read/1` answers it, such as `:enoent`),
  `{:error, {:parse_error, path, reason}}` when it is not valid Elixir
  (`reason` as `Code.string_to_quoted/2` answers it). Returns
  `{:error, :invalid_argument}` when `paths` is not a list of strings.
  """
  def list_system_envs(paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case list_file_system_envs(path) do
        {:ok, system_envs} -> {:cont, {:ok, acc ++ system_envs}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def list_system_envs(_paths), do: {:error, :invalid_argument}

  defp list_file_system_envs(path) do
    with {:ok, source} <- read_file(path),
         {:ok, ast} <- parse_source(source, path) do
      system_envs =
        ast
        |> collect_reads([], [])
        |> Enum.reverse()
        |> Enum.map(&Map.put(&1, :file, path))

      {:ok, system_envs}
    end
  end

  defp read_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        {:error, {:read_error, path, reason}}
    end
  end

  defp read_file(_path), do: {:error, :invalid_argument}

  defp parse_source(source, path) do
    case Code.string_to_quoted(source, file: path) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, reason} ->
        {:error, {:parse_error, path, reason}}
    end
  end

  # Walks the AST by hand rather than with `Macro.prewalk/3`: a read must
  # know the `if`s above it, and which branch of each it sits in.
  defp collect_reads({:if, _meta, [condition, blocks]}, inside, acc) when is_list(blocks) do
    source = Macro.to_string(condition)
    acc = collect_reads(condition, inside, acc)
    acc = collect_reads(Keyword.get(blocks, :do), [source | inside], acc)
    collect_reads(Keyword.get(blocks, :else), ["not (#{source})" | inside], acc)
  end

  defp collect_reads({{:., _, [_module, :get_system_env!]}, meta, [name | rest]}, inside, acc)
       when is_binary(name) do
    read = %{
      name: name,
      line: meta[:line],
      read: :get_system_env!,
      inside: Enum.reverse(inside),
      defaults: config_envs_defaults(rest),
      values: config_envs_values(rest)
    }

    collect_reads(rest, inside, [read | acc])
  end

  defp collect_reads(
         {{:., _, [{:__aliases__, _, [:System]}, function]}, meta, [name | rest]},
         inside,
         acc
       )
       when function in @system_reads and is_binary(name) do
    read = %{
      name: name,
      line: meta[:line],
      read: function,
      inside: Enum.reverse(inside),
      defaults: Map.new(@config_envs, &{&1, system_default(function, rest)}),
      values: Map.new(@config_envs, &{&1, system_value(function, rest)})
    }

    collect_reads(rest, inside, [read | acc])
  end

  defp collect_reads({form, meta, args}, inside, acc) when is_list(meta) do
    acc = collect_reads(form, inside, acc)
    collect_reads(args, inside, acc)
  end

  defp collect_reads({left, right}, inside, acc) do
    acc = collect_reads(left, inside, acc)
    collect_reads(right, inside, acc)
  end

  defp collect_reads(nodes, inside, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_reads(&1, inside, &2))
  end

  defp collect_reads(_leaf, _inside, acc), do: acc

  defp config_envs_defaults([]), do: Map.new(@config_envs, &{&1, "required"})

  defp config_envs_defaults([defaults | _opts]) do
    if Keyword.keyword?(defaults) do
      Map.new(@config_envs, fn config_env ->
        case Keyword.fetch(defaults, config_env) do
          {:ok, default} -> {config_env, Macro.to_string(default)}
          :error -> {config_env, "required"}
        end
      end)
    else
      # The defaults are an expression: its value is only known when the
      # file is evaluated, so every config env shows the expression.
      Map.new(@config_envs, &{&1, Macro.to_string(defaults)})
    end
  end

  defp config_envs_values([defaults | _opts]) when is_list(defaults) do
    Map.new(@config_envs, fn config_env ->
      case Keyword.keyword?(defaults) and Keyword.fetch(defaults, config_env) do
        {:ok, default} when is_binary(default) -> {config_env, default}
        _other -> {config_env, nil}
      end
    end)
  end

  defp config_envs_values(_rest), do: Map.new(@config_envs, &{&1, nil})

  defp system_value(:get_env, [default]) when is_binary(default), do: default
  defp system_value(_function, _rest), do: nil

  defp system_default(:get_env, [default]), do: Macro.to_string(default)
  defp system_default(:fetch_env!, _rest), do: "required"
  defp system_default(_function, _rest), do: "-"
end
