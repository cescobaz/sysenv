# Sysenv

Read the configuration of an Elixir application without silent holes.

- `Sysenv.get_system_env!/3` reads an OS environment variable in a config
  file, with one default per config env. No default for the config env and
  no variable: the system does not boot.
- `Sysenv.fetch_env/2` reads the application environment and returns
  `{:error, :not_set}` where `Application.fetch_env/2` answers `:error`,
  `nil` or `""`.
- `mix sysenv` prints every OS environment variable the config files read,
  and writes an env file out of them.

## Installation

```elixir
def deps do
  [
    {:sysenv, "~> 0.1.0"}
  ]
end
```

## In a config file

```elixir
# config/runtime.exs
import Config

config :my_app,
  s3_region: Sysenv.get_system_env!("S3_REGION", dev: "fra1", test: "fra1", prod: "fra1"),
  s3_secret_key: Sysenv.get_system_env!("S3_SECRET_KEY", dev: nil, test: nil),
  pool_size: Sysenv.get_system_env!("POOL_SIZE", [dev: "10", test: "10"], cast: :pos_integer),
  enable_jobs: Sysenv.get_system_env!("ENABLE_JOBS", [dev: "true", test: "false"], cast: :boolean)
```

The defaults are keyed by config env (`:dev`, `:test`, `:prod`). A variable
that is not set, or set to `""`, takes the default of the current config
env. A config env with no default makes the variable required there: above,
`S3_SECRET_KEY` may be missing in `dev` and `test`, and must be set in
`prod`.

`:cast` is one of `:integer`, `:non_neg_integer`, `:pos_integer` and
`:boolean`. A value of the wrong type raises.

Use it in `config/runtime.exs`: dependencies are compiled before that file
is evaluated, but not before `config/config.exs`.

## In the application

```elixir
with {:ok, api_key} <- Sysenv.fetch_env(:my_app, [:firecrawl, :api_key]) do
  # ...
end
```

The key is an atom, or the path to a key nested in keyword lists. A key
that is missing, `nil` or `""` gives `{:error, :not_set}`.

## The mix task

```console
$ mix sysenv
VARIABLE       DEV       TEST      PROD      READ AT                INSIDE
S3_REGION      "fra1"    "fra1"    "fra1"    config/runtime.exs:5
S3_SECRET_KEY  nil       nil       required  config/runtime.exs:6
POOL_SIZE      "10"      "10"      required  config/runtime.exs:7
PHX_HOST       required  required  required  config/runtime.exs:13  config_env() == :prod
```

```console
$ mix sysenv --generate dev            # writes dev.env, to `source`
$ mix sysenv --generate prod --docker  # writes prod.env, for `docker --env-file`
$ mix sysenv --generate dev --force    # replaces an existing dev.env
```

The config files are parsed, never evaluated. Reads through
`System.get_env`, `System.fetch_env` and `System.fetch_env!` are listed too.
A variable whose name is not a string literal is not listed.

## License

MIT
