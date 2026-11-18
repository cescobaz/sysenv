# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`sysenv` is a small Elixir library (Hex package, v0.1.0 unreleased, repo `cescobaz/sysenv`) for reading application configuration without silent holes. It has no runtime dependencies; `ex_doc` is the only dep (dev only). There is no `config/` directory in this repo: the library is meant to be used from the `config/runtime.exs` of the host application.

## Commands

```sh
mix deps.get
mix compile --warnings-as-errors
mix format                       # mix format --check-formatted to verify
mix test
mix test test/sysenv/config_test.exs        # one file
mix test test/sysenv/config_test.exs:16     # one test, by line
mix docs                         # ExDoc, README.md is the main page
mix hex.build                    # package tarball (files listed in mix.exs `package/0`)
```

No Credo, Dialyzer or CI is configured.

## Architecture

Three modules, two independent halves that share nothing but the name `get_system_env!`:

**Runtime half — `lib/sysenv.ex`**

- `Sysenv.get_system_env!/3` is a plain function. It reads the config env with `Config.config_env()`, which looks it up in the process dictionary that `Config.Reader` fills while it evaluates a config file. So it works in a config file (or a function one calls) with no `require`, and raises anywhere else. Tests exercise it by writing a config file to a tmp dir and reading it with `Config.Reader.read!(path, env: env)`.
- An unset variable and one set to `""` are treated the same (fall back to the default for the current config env; raise when there is none). `:cast` only applies to binaries: a non-string default is returned as is.
- `Sysenv.fetch_env/2` wraps `Application.fetch_env/2`, accepts an atom or a path through nested keyword lists, and collapses missing / `nil` / `""` into `{:error, :not_set}`. `false` is a value.

**Static-analysis half — `lib/sysenv/config.ex` + `lib/mix/tasks/sysenv.ex`**

- `Sysenv.Config.list_system_envs/1` parses config files with `Code.string_to_quoted/2` and **never evaluates them**. `collect_reads/3` is a hand-written AST walk (not `Macro.prewalk`) because each read must carry the stack of enclosing `if` conditions, including which branch it is in (the `else` branch is recorded as `"not (<condition>)"`).
- A read is matched by shape: any remote call named `get_system_env!` on **any** module (so aliases and user wrappers are found), or `System.get_env` / `fetch_env` / `fetch_env!`. Only string-literal names are listed.
- Each read is a map: `name`, `file`, `line`, `read`, `inside`, `defaults` (source text per config env, `"required"`, or `"-"`), `values` (the default per config env only when it is a string literal, else `nil`). `defaults` feeds the printed table; `values` feeds the env file.
- `build_env_file/3` filters out reads whose `inside` conditions exclude the target config env. This is done by **string comparison** against `Macro.to_string/1` output (`"config_env() == :prod"`, `"not (config_env() == :dev)"`), so only that exact form of condition is understood. Reads through `System` are written as comments (`# NAME=`), because an empty value would differ from an unset one there.
- `Mix.Tasks.Sysenv` is a thin shell: globs `config/*.exs` relative to the current directory, prints the table or writes `<config env>.env`, and turns `{:error, reason}` tuples into `Mix.raise/1`. It returns the `{:ok, _}` result, which the tests assert on.

## Conventions

- Public functions return `{:ok, value}` / `{:error, reason}` with tagged reasons (`{:read_error, path, posix}`, `{:parse_error, path, reason}`, `:invalid_argument`, …) and guard their argument types, with a catch-all clause returning `{:error, :invalid_argument}`. Only `get_system_env!` and the mix task raise.
- Every public function has a `@doc` written in plain, short sentences; keep `README.md`, the `@moduledoc`s and `CHANGELOG.md` in step when behaviour changes.
- Tests that need files use `@moduletag :tmp_dir`. The mix task test is `async: false` because it `File.cd!`s into the tmp dir; the others are async and use per-test unique application env keys / variable names.
- `/*.env` is git-ignored: files produced by `mix sysenv --generate` at the repo root are not to be committed.
