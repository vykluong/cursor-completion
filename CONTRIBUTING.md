# Contributing

## Layout

[`src/_cursor-agent`](src/_cursor-agent) (`#compdef agent cursor-agent`) is the whole product. Its tables are written from [`tools/cli-surface.txt`](tools/cli-surface.txt), a snapshot generated from the installed CLI. The tests (`tests/`) and tools (`tools/`) are plain zsh. There is no build step and no package manager.

## Scope: the four surface tiers

1. **Visible in `--help`**: completed.
2. **Hidden but registered** (commands and options the CLI accepts but `--help` does not list, such as `shell-integration` or `--repo-endpoint`): completed.
3. **Feature-gated** (account-dependent: `automations`, `cloud`, `env`): completed, in their own labeled block and `gated-commands` tag, removable in one edit. These are known from static mining of the CLI bundle only, so they may not be available on every account.
4. **Dev-only** (compiled out of release builds, such as `dev`, `dev-login`, `--ian-dev`): excluded, since the binary cannot execute them.

`cursor`, the Cursor IDE's shell command, is deliberately not claimed.

## Design policy

- **Fully static.** The script never runs `agent`, reads no local state (no `.cursor/mcp.json`, chat stores, or config), uses no `eval`, and forks no subprocesses. Completion stays fast and has no side effects.
- **Runtime-only values get a hint, not candidates.** Models, teams, MCP identifiers, chat IDs, workspaces, persist sessions, and marketplaces depend on the account and machine, so the script shows a descriptive message instead (for `--model`, it points at `agent --list-models`).
- **Secrets complete nothing.** `--api-key`, `--auth-token`, `--local-agent-api-key`, and `bedrock configure --access-key`/`--secret-key` offer no candidates.
- **Leaf contexts complete leaf options only.** The CLI also accepts root options after a subcommand, but offering every root flag under `agent mcp list` is noise. Before a subcommand, and after a first word that is not a command (a prompt), root options stay available.
- **Space-separated values only.** Values complete as `--mode plan`, not `--mode=plan`, matching the CLI's own usage hints. Do not declare the `--opt=value` form.
- **No commands after an optional-value option.** After `--resume`, `-w`/`--worktree`, or a bare worker `--pool`, the CLI takes the next word as the value, so no commands are offered there (except the words that end a worker `--pool`).
- **No model shortcuts.** The hidden model shortcuts (`gpt-5`, `gpt5`, `opus`, `sonnet`) are left out because `agent --model <model>` replaces them.
- **Mechanical function names.** Helpers are `_cursor_agent_*`, and per-command function names derive mechanically from the command path (`agent plugin marketplace add` is `_cursor_agent_plugin_marketplace_add`). `tools/check-coverage.zsh` enforces this.

Every command and flag in tiers 1 to 3 is completed, except the deliberate deviations in [`tools/coverage-exceptions.txt`](tools/coverage-exceptions.txt). A hidden or gated entry carries a comment stating its class (hidden or gated) and how that class is verified. Per-entry probe results, dates, and versions live in the snapshot, not in script comments.

## Testing

```bash
zsh tests/run-tests.zsh                       # golden-file suite (CI runs it on ubuntu and macos)
zsh tests/run-tests.zsh 'mcp-*'               # subset, glob on case name
zsh tests/zcomp-runner.zsh 'agent mcp '       # print candidates for one buffer
DOUBLE_TAB=1 zsh tests/zcomp-runner.zsh 'agent '   # simulate a second TAB
```

The harness drives a real interactive zsh through `zpty` and never invokes the `agent` binary. Each file in `tests/cases/` holds one buffer and its expected candidates; the format is documented at the top of [`tests/run-tests.zsh`](tests/run-tests.zsh). Before any case runs, the suite checks the script with `zsh -n` and runs the coverage check below.

## Tooling

- [`tools/check-coverage.zsh`](tools/check-coverage.zsh) compares `src/_cursor-agent` with the snapshot in both directions. It needs no CLI. Deliberate deviations are listed, with reasons, in `tools/coverage-exceptions.txt`.
- [`tools/check-drift.zsh`](tools/check-drift.zsh) diffs the installed CLI against `tools/cli-surface.txt` (exit 1 on drift), and `zsh tools/check-drift.zsh snapshot` accepts a new surface. It is the only part of the project that executes the CLI, in isolated throwaway directories, and CI never runs it. `zsh tools/check-drift.zsh diff <old-version-dir> <new-version-dir>` previews an update statically, and `--help` lists all modes and exit codes.
- `tools/cli-surface.txt` is generated; never hand-edit it. When the CLI surface changes, regenerate it with `zsh tools/check-drift.zsh snapshot` and commit the result in the same change.
- `tools/coverage-exceptions.txt` lists deliberate deviations, one per line: `<function> | <code> | <entry> | <reason>`. The reason is required, and a line matching no finding is itself a finding (`exception-unused`), so delete stale lines.

## Executing the CLI (hazards)

Only `tools/check-drift.zsh` may run `agent`, and CI never does. The long form is the "Execution half: running the CLI" comment block in `tools/check-drift.zsh`; `guard_argv` and `run_isolated` enforce it.

- Every invocation, even `--help`, does a DNS lookup of `api2.cursor.sh` and may warm Statsig.
- An unknown first word is a prompt and starts a real session. Never run a line that could parse cleanly (no bare booleans, no positional words).
- `agent persist attach --help` and `agent persist stop --help` treat `--help` as a session name. Never run them.
- Run each invocation in a fresh throwaway directory (`HOME`, `CURSOR_CONFIG_DIR`, `TMPDIR`, and a cwd outside any git repo) with an environment built from scratch (no `CURSOR_*`; `AGENT_CLI_CREDENTIAL_STORE=memory` keeps it off the login keychain), `</dev/null`, and a wall-clock cap that kills its process group.
- Only two argv shapes ever run: `<command words> --help` and the option probe `<command words> <flag> --zz-bogus-1 --zz-bogus-2`. One trailing bogus flag is not enough: a required value or a shadowing root option can eat it, and the line then parses cleanly (`worker start --data-dir --zz-bogus` starts a worker). `run_isolated` and `guard_argv` enforce this; never loosen them.
- The safety analysis covered builds 2026.10.01-e373342 and 2026.10.16-e3cb207 only, so `check-drift.zsh diff` is static unless given `--full`, which executes both versions.

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

## Style

- Commit subjects are imperative and capitalized, no conventional-commit prefix (`Add ...`, `Fix ...`, `Update _cursor-agent for CLI 2026.10.16-e3cb207`).
- Prose uses American English and avoids em dashes.
