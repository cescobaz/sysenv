defmodule Mix.Tasks.Sysenv do
  @shortdoc "Prints the OS environment variables the config files read"

  @moduledoc """
  Prints every OS environment variable read in `config/*.exs`, with its
  default in each config env.

      mix sysenv
      mix sysenv --full
      mix sysenv --generate dev
      mix sysenv --generate dev --force
      mix sysenv --generate dev --docker

  A variable read through `Sysenv.get_system_env!/3` shows its default for
  `dev`, `test` and `prod`, or `required` when it has none. A variable read
  through `System` shows the default of the call, or `-` when the read
  answers `nil` for a variable that is not set. `INSIDE` is the `if` the read
  sits in.

  A default longer than 40 characters is cut, unless `--full` is given.

  `--generate <config env>` writes the file `<config env>.env` instead of
  printing the table, see `Sysenv.Config.build_env_file/3` for its content.
  The file is written for a shell (`source`), or for Docker (`--env-file`)
  with `--docker`. A file that already exists is only replaced with
  `--force`.

  The files are parsed, never evaluated: the list holds the reads of every
  branch, and a variable whose name is not a string literal is not listed.
  """

  use Mix.Task

  alias Sysenv.Config

  @max_default_length 40

  @impl Mix.Task
  def run(args) do
    {opts, _args} =
      OptionParser.parse!(args,
        strict: [full: :boolean, generate: :string, force: :boolean, docker: :boolean]
      )

    result =
      with {:ok, system_envs} <-
             "config/*.exs" |> Path.wildcard() |> Enum.sort() |> Config.list_system_envs() do
        case Keyword.fetch(opts, :generate) do
          {:ok, config_env} ->
            generate_env_file(system_envs, config_env, opts)

          :error ->
            system_envs
            |> format_table(Keyword.get(opts, :full, false))
            |> Enum.each(fn line -> Mix.shell().info(line) end)

            {:ok, system_envs}
        end
      end

    case result do
      {:ok, _result} ->
        result

      {:error, reason} ->
        Mix.raise(format_error(reason))
    end
  end

  defp generate_env_file(system_envs, config_env, opts) do
    path = "#{config_env}.env"
    format = if Keyword.get(opts, :docker, false), do: :docker, else: :shell

    with {:ok, content} <- Config.build_env_file(system_envs, config_env, format: format),
         {:ok, path} <- write_env_file(path, content, Keyword.get(opts, :force, false)) do
      Mix.shell().info("#{path} written")
      {:ok, path}
    end
  end

  defp write_env_file(path, content, force?) do
    if File.exists?(path) and not force? do
      {:error, {:write_error, path, :eexist}}
    else
      case File.write(path, content) do
        :ok ->
          {:ok, path}

        {:error, reason} ->
          {:error, {:write_error, path, reason}}
      end
    end
  end

  defp format_error(:unsupported_config_env) do
    "The config env must be one of #{Enum.join(Config.config_envs(), ", ")}"
  end

  defp format_error({:write_error, path, :eexist}) do
    "#{path} already exists, pass --force to replace it"
  end

  defp format_error({:write_error, path, reason}) do
    "#{path} could not be written: #{:file.format_error(reason)}"
  end

  defp format_error({:read_error, path, reason}) do
    "#{path} could not be read: #{:file.format_error(reason)}"
  end

  defp format_error({:parse_error, path, reason}) do
    "#{path} could not be parsed: #{inspect(reason)}"
  end

  defp format_error(reason), do: "mix sysenv failed: #{inspect(reason)}"

  defp format_table(system_envs, full?) do
    header = ["VARIABLE", "DEV", "TEST", "PROD", "READ AT", "INSIDE"]

    rows =
      Enum.map(system_envs, fn system_env ->
        defaults = Enum.map(Config.config_envs(), &cut(system_env.defaults[&1], full?))

        [system_env.name] ++
          defaults ++
          ["#{system_env.file}:#{system_env.line}", Enum.join(system_env.inside, " and ")]
      end)

    widths =
      [header | rows]
      |> Enum.zip_with(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map([header | rows], fn row ->
      row
      |> Enum.zip_with(widths, &String.pad_trailing/2)
      |> Enum.join("  ")
      |> String.trim_trailing()
    end)
  end

  defp cut(default, true), do: default

  defp cut(default, false) do
    if String.length(default) > @max_default_length do
      String.slice(default, 0, @max_default_length - 1) <> "…"
    else
      default
    end
  end
end
