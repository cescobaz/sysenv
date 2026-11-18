# Changelog

## v0.1.0 (unreleased)

First release.

- `Sysenv.get_system_env!/3` reads an OS environment variable in a config
  file, with one default per config env and an optional `:cast`.
- `Sysenv.fetch_env/2` reads the application environment and answers
  `{:error, :not_set}` for a key that is missing, `nil` or `""`.
- `mix sysenv` prints the OS environment variables the config files read;
  `--generate <config env>` writes an env file for a shell or for Docker.
