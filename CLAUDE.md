# CLAUDE.md

## What this is

A single Zsh completion script, `src/_cursor-agent` (`#compdef agent cursor-agent`), for the Cursor CLI. There is no build step and no package manager. Everything is plain zsh. Target CLI: 2026.10.01-e373342.

## Commands

```bash
zsh tests/run-tests.zsh              # full golden-file suite (CI runs this on ubuntu + macos)
zsh tests/run-tests.zsh 'mcp-*'      # subset, glob on case name
zsh tests/zcomp-runner.zsh 'agent mcp '   # print candidates for one buffer
DOUBLE_TAB=1 zsh tests/zcomp-runner.zsh 'agent '   # simulate a second TAB
zsh -n src/_cursor-agent             # syntax check (CI gate; the suite also runs it as preflight)
zsh tools/check-coverage.zsh         # compare src/_cursor-agent with the snapshot, both directions (no binary needed; the suite also runs it as preflight)
zsh tools/check-drift.zsh            # diff installed CLI against tools/cli-surface.txt (runs `agent`; exit 1 drift, 2 tool or miner failure)
zsh tools/check-drift.zsh snapshot   # accept the new CLI surface
zsh tools/check-drift.zsh dump --static   # mined records only; executes nothing
zsh tools/check-drift.zsh diff <old-version-dir> <new-version-dir>   # compare two installed versions, statically
zsh tools/check-drift.zsh --help     # modes, flags (--version-dir, --static, --full), exit codes
```

The test harness drives a real interactive zsh through zpty. It never invokes the `agent` binary; only `tools/check-drift.zsh` does.

## Scope: the four surface tiers

1. Visible in `--help`: completed.
2. Hidden but registered (`.hideHelp()`, `{hidden:!0}`): completed.
3. Feature-gated (Statsig, account-dependent; `automations`, `cloud`, `env`): completed, in its own labelled block and `gated-commands` tag, removable in one edit. Known from static mining only.
4. Dev-only, compiled out (`dev`, `dev-login`, `--ian-dev`, ...): excluded, since the binary cannot execute it.

## Editing src/_cursor-agent

- Fully static: the script never runs `agent`, never reads `.cursor/mcp.json`, chat stores, or any other local state, uses no `eval`, and forks no subprocesses. Runtime-only values (models, teams, MCP identifiers, chat IDs, workspaces, persist sessions, marketplaces) get a descriptive message and no candidates. Secret-bearing options (`--api-key`, `--auth-token`, `--local-agent-api-key`, `bedrock configure --access-key/--secret-key`) complete nothing.
- Every command and flag the binary accepts in tiers 1 to 3 is completed, including ones `--help` hides, except the deliberate deviations in `tools/coverage-exceptions.txt`. The hidden model shortcuts (`gpt-5`, `gpt5`, `opus`, `sonnet`) are left out because `agent --model <model>` replaces them. A hidden or gated entry carries a comment stating its class (hidden or gated) and how that class is verified. Per-entry probe results, dates, and versions live in the generated snapshot `tools/cli-surface.txt`, not in script comments.
- Keep the target-version header comment in sync with the CLI version the tables were generated against. It is the only place the version appears.
- Leaf contexts complete leaf options only. Commander also accepts root options after a subcommand, but that is deliberate noise reduction. Before a subcommand, and after a first word that is not a command (the prompt case), root options stay available.
- Values complete in the space-separated form only (`--mode plan`). Do not declare the `--opt=value` form; the CLI's own hints do not use it.
- No commands after an optional-value option: commander takes the next word as the value, so after `--resume` or `-w/--worktree` only the value message is offered, and after a bare worker `--pool` only the `--pool` stop words.
- Naming: helpers are `_cursor_agent_*`. Per-command function names derive mechanically from the command path (`agent plugin marketplace add` is `_cursor_agent_plugin_marketplace_add`).
- Write `{--a,--b}` brace pairs inline inside the `_arguments` array. Never store a brace spec in a scalar; it will not expand.
- Every behavior change needs a matching case in `tests/cases/`. Regenerate expectations with `zsh tests/zcomp-runner.zsh '<buffer>'` and review them against `tools/cli-surface.txt`; do not hand-type them.
- The number of tokens used to edit files is best minimized, all else being equal. Therefore, when it will not affect the end result, try to surgically edit a file rather than rewrite the entire thing.

## Test case files (tests/cases/*.txt)

- Format is documented at the top of `tests/run-tests.zsh` (`buffer=` line, optional `# mode:` and `# double-tab` lines, set comparison). Modes are `exact` (default), `contains`, and `empty`. An `empty` case lists no expected lines and passes only if the harness's run marker shows `_cursor-agent` ran cleanly (runner exit 0, not 3), so a load error cannot pass as "offers nothing".

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
- The safety analysis covered build 2026.10.01-e373342 only, so `check-drift.zsh diff` is static unless given `--full`, which executes both versions.

## Updating for a new CLI release

To preview an update before switching, run `zsh tools/check-drift.zsh diff <old-version-dir> <new-version-dir>`.

1. `agent update`.
2. `zsh tools/check-drift.zsh`. If it exits 2 ("miner needs attention"), fix the miner first.
3. `zsh tools/check-drift.zsh snapshot`.
4. `zsh tools/check-coverage.zsh` and edit the functions it lists.
5. Regenerate affected test cases with `zsh tests/zcomp-runner.zsh '<buffer>'`.
6. `zsh tests/run-tests.zsh`.
7. Bump the target-version header in `src/_cursor-agent`.
8. Add a CHANGELOG section and tag `cli-<version>`.

## Style

- Commit subjects are imperative and capitalized, no conventional-commit prefix (`Add ...`, `Fix ...`, `Update _cursor-agent for CLI 2026.10.01-e373342`).
- Prose uses American English and avoids em dashes.
