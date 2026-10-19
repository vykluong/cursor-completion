# CLAUDE.md

## What this is

A single Zsh completion script, `src/_cursor-agent` (`#compdef agent cursor-agent`), for the Cursor CLI. There is no build step and no package manager. Everything is plain zsh.

## Commands

```bash
zsh tests/run-tests.zsh              # golden-file suite; preflights `zsh -n` and check-coverage
zsh tests/run-tests.zsh 'mcp-*'      # subset, glob on case name
zsh tests/zcomp-runner.zsh 'agent mcp '   # print candidates for one buffer
DOUBLE_TAB=1 zsh tests/zcomp-runner.zsh 'agent '   # simulate a second TAB
zsh tools/check-coverage.zsh         # script vs. snapshot, both directions; executes nothing
zsh tools/check-drift.zsh            # installed CLI vs. tools/cli-surface.txt; RUNS `agent` (exit 1 drift, 2 tool or miner failure)
zsh tools/check-drift.zsh snapshot   # accept the new CLI surface
zsh tools/check-drift.zsh --help     # other modes (dump, diff) and flags (--static, --full, --version-dir)
```

The test harness drives a real interactive zsh through zpty and never invokes `agent`.

## Scope: the four surface tiers

1. Visible in `--help`: completed.
2. Hidden but registered (`.hideHelp()`, `{hidden:!0}`): completed.
3. Feature-gated (Statsig, account-dependent; `automations`, `cloud`, `env`): completed, in its own labelled block and `gated-commands` tag, removable in one edit. Known from static mining only.
4. Dev-only, compiled out (`dev`, `dev-login`, `--ian-dev`, ...): excluded, since the binary cannot execute it.

## Editing src/_cursor-agent

- Fully static: the script never runs `agent`, never reads `.cursor/mcp.json`, chat stores, or any other local state, uses no `eval`, and forks no subprocesses. Runtime-only values (models, teams, MCP identifiers, chat IDs, workspaces, persist sessions, marketplaces) get a descriptive message and no candidates. Secret-bearing options (`--api-key`, `--auth-token`, `--local-agent-api-key`, `bedrock configure --access-key/--secret-key`) complete nothing.
- Every command and flag the binary accepts in tiers 1 to 3 is completed, including ones `--help` hides, except the deliberate deviations in `tools/coverage-exceptions.txt`. The hidden model shortcuts (`gpt-5`, `gpt5`, `opus`, `sonnet`) are left out because `agent --model <model>` replaces them. A hidden or gated entry carries a comment stating its class (hidden or gated) and how that class is verified. Per-entry probe results, dates, and versions live in the generated snapshot `tools/cli-surface.txt`, not in script comments.
- Keep the target-version header comment in sync with the CLI version the tables were generated against. It is the script's only copy of the version.
- Leaf contexts complete leaf options only. Commander also accepts root options after a subcommand, but that is deliberate noise reduction. Before a subcommand, and after a first word that is not a command (the prompt case), root options stay available.
- Values complete in the space-separated form only (`--mode plan`). Do not declare the `--opt=value` form; the CLI's own hints do not use it.
- No commands after an optional-value option: commander takes the next word as the value, so after `--resume` or `-w/--worktree` only the value message is offered, and after a bare worker `--pool` only the `--pool` stop words.
- Naming: helpers are `_cursor_agent_*`. Per-command function names derive mechanically from the command path (`agent plugin marketplace add` is `_cursor_agent_plugin_marketplace_add`).
- Write `{--a,--b}` brace pairs inline inside the `_arguments` array. Never store a brace spec in a scalar; it will not expand.
- Every behavior change needs a matching case in `tests/cases/`. Regenerate expectations with `zsh tests/zcomp-runner.zsh '<buffer>'` and review them against `tools/cli-surface.txt`; do not hand-type them.
- Prefer surgical edits over rewriting a whole file when the result is the same; it saves tokens.

## Test case files (tests/cases/*.txt)

- The format and modes (`exact`, `contains`, `empty`) are documented at the top of `tests/run-tests.zsh`. An `empty` case also requires the runner's clean-run marker (exit 0, not 3), so a load error cannot pass as "offers nothing".

## Editing the zsh tooling (tests/, tools/)

- Unquoted `$c` does not word-split in zsh. Use `${=c}` when a variable holds a multi-word command path, or `agent "mcp list" --help` is a single unknown word.
- Never declare a local named `path`; zsh ties it to `PATH` and wipes command lookup for the whole dynamic scope.
- `tools/cli-surface.txt` is generated; never hand-edit it. When the CLI surface changes, regenerate it with `zsh tools/check-drift.zsh snapshot` and commit the result in the same change.
- `tools/coverage-exceptions.txt` lists deliberate deviations, one per line: `<function> | <code> | <entry> | <reason>`; the reason is required, and a line matching no finding is itself a finding (`exception-unused`), so delete stale lines.
- The local `grep` may be ugrep, which fails on the bundle's long lines. Mine `index.js` with perl or `/usr/bin/grep`.

## Hazards of executing the CLI

Only `tools/check-drift.zsh` may run `agent`, and CI never does.

- `agent` is a bash wrapper running bundled Node on `index.js` under `~/.local/share/cursor-agent/versions/<version>/`, not a native binary.
- Every invocation, even `--help`, does a DNS lookup of `api2.cursor.sh` and may warm Statsig.
- An unknown first word is a prompt and starts a real session. Never run a line that could parse cleanly (no bare booleans, no positional words).
- `agent persist attach --help` and `agent persist stop --help` treat `--help` as a session name. Never run them.
- Run each invocation in a fresh throwaway directory (`HOME`, `CURSOR_CONFIG_DIR`, `TMPDIR`, and a cwd outside any git repo) with an environment built from scratch (no `CURSOR_*`; `AGENT_CLI_CREDENTIAL_STORE=memory` keeps it off the login keychain), `</dev/null`, and a wall-clock cap that kills its process group.
- Only two argv shapes ever run: `<command words> --help` and the option probe `<command words> <flag> --zz-bogus-1 --zz-bogus-2`. One trailing bogus flag is not enough: a required value or a shadowing root option can eat it, and the line then parses cleanly (`worker start --data-dir --zz-bogus` starts a worker). `run_isolated` and `guard_argv` enforce this; never loosen them.
- The safety analysis covered builds 2026.10.01-e373342 and 2026.10.16-e3cb207 only, so `check-drift.zsh diff` is static unless given `--full`, which executes both versions.

## Updating for a new CLI release

Follow the checklist under "Release process" in `CHANGELOG.md`.

## Style

- Commit subjects are imperative and capitalized, no conventional-commit prefix (`Add ...`, `Fix ...`, `Update _cursor-agent for CLI 2026.10.16-e3cb207`).
- Prose uses American English and avoids em dashes.
