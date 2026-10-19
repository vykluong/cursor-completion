# Changelog

All notable changes to the `_cursor-agent` zsh completion script are documented
in this file, one section per `cli-<version>` tag.

The release checklist is in CONTRIBUTING.md.

## [cli-2026.10.16-e3cb207] - 2026-10-16

Verified against Cursor CLI 2026.10.16-e3cb207.

### Added

- `worker --mcp-tool-timeout <server[/tool]=seconds>` (repeatable).
- `worker controller --identity-audience <aud>`, which excludes
  `--warm-idle`.

### Removed

- Gated `env publish` and `env get --ref`.

### Changed

- `env get --personal-only` and `env deploy --delete-personal-on-team-write`
  are now hidden.
- The `env delete` positional is `<publicId>`, and the descriptions for
  `env`, `env get`, `env delete`, and `env delete --team` follow the CLI.

### Verification

- A full drift run (70 help screens, 47 option probes) exited 0 against the
  new build with no leaked processes.
- A static diff between the two bundles agrees with the executed view.

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

[cli-2026.10.16-e3cb207]: https://github.com/vykluong/cursor-completion/releases/tag/cli-2026.10.16-e3cb207
[cli-2026.10.01-e373342]: https://github.com/vykluong/cursor-completion/releases/tag/cli-2026.10.01-e373342
