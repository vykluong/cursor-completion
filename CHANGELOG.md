# Changelog

All notable changes to the `_cursor-agent` zsh completion script are documented
in this file, one section per `cli-<version>` tag.

## Release process

To preview an update before switching, run
`zsh tools/check-drift.zsh diff <old-version-dir> <new-version-dir>`.

1. `agent update`.
2. `zsh tools/check-drift.zsh`. If it exits 2 ("miner needs attention"), fix
   the miner first.
3. `zsh tools/check-drift.zsh snapshot`.
4. `zsh tools/check-coverage.zsh` and edit the functions it lists.
5. Regenerate affected test cases with `zsh tests/zcomp-runner.zsh '<buffer>'`.
6. `zsh tests/run-tests.zsh`.
7. Bump the target-version header in `src/_cursor-agent`.
8. Add a CHANGELOG section and tag `cli-<version>`.

## [cli-2026.10.01-e373342] - 2026-10-04

Verified against Cursor CLI 2026.10.01-e373342. First release.

- `src/_cursor-agent` (`#compdef agent cursor-agent`): completion for the
  Cursor CLI, written from the generated snapshot `tools/cli-surface.txt`.
  - Scope: every command and option visible in `--help`, every hidden but
    registered one, and the feature-gated `automations`, `cloud`, and `env`
    trees (in their own labelled block and `gated-commands` tag). Dev-only
    surface compiled out of the binary (`dev`, `dev-login`, `--ian-dev`, ...)
    is excluded.
  - Fully static: never runs the CLI, reads no local state, uses no `eval`,
    and forks no subprocesses. Runtime-only values (models, teams, MCP
    identifiers, chat IDs, workspaces, persist sessions, marketplaces) get a
    descriptive message and no candidates. Secret-bearing options
    (`--api-key`, `--auth-token`, `--local-agent-api-key`,
    `bedrock configure --access-key`/`--secret-key`) complete nothing.
  - Leaf contexts complete leaf options only; root options stay available
    before a subcommand and in the prompt case.
  - Values complete in the space-separated form only (`--mode plan`); the
    `--opt=value` form is not declared. Commands are not offered where an
    optional-value option takes the word.
- Golden-file test suite: `tests/run-tests.zsh` drives a real interactive zsh
  through zpty (`tests/zcomp-runner.zsh`) over 325 cases in `tests/cases/`,
  with `exact`, `contains`, and `empty` modes and double-TAB simulation. Its
  preflights run `zsh -n` on the script and `tools/check-coverage.zsh`.
- `tools/check-drift.zsh`: mines the installed CLI bundle, walks `--help`,
  and probes hidden entries in an isolated, scrubbed environment, then diffs
  the result against the committed snapshot `tools/cli-surface.txt`. Modes
  `check`, `snapshot`, `dump`, and `diff` (two installed versions,
  statically unless `--full`); exits 2 when the miner needs attention. It is
  the only tool that executes the CLI, and it is run by hand, never in CI.
- `tools/check-coverage.zsh`: compares `src/_cursor-agent` with the snapshot
  in both directions without the binary. Deliberate deviations are listed,
  each with a reason, in `tools/coverage-exceptions.txt`.
- GitHub Actions CI (`.github/workflows/ci.yml`): `zsh -n` on the script and
  all tooling, then the test suite on Ubuntu and macOS.

[cli-2026.10.01-e373342]: https://github.com/vykluong/cursor-completion/releases/tag/cli-2026.10.01-e373342
