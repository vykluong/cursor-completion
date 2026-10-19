# CLAUDE.md

## What this is

A single Zsh completion script, `src/_cursor-agent` (`#compdef agent cursor-agent`), for the Cursor CLI. There is no build step and no package manager. Everything is plain zsh. Design policy, tiers, tooling, hazards, and the release runbook are in CONTRIBUTING.md; the script header and each tool's header document themselves.

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

## Editing src/_cursor-agent

- Fully static: never run `agent`, read local state, use `eval`, or fork a subprocess (details in the script header).
- Every behavior change needs a case in `tests/cases/`. Regenerate expectations with `zsh tests/zcomp-runner.zsh '<buffer>'` and review them against `tools/cli-surface.txt`; never hand-type them.
- A hidden or gated entry carries a comment stating its class. Probe results, dates, and versions stay out of script comments.
- Write `{--a,--b}` brace pairs inline inside the `_arguments` array, never in a scalar; it will not expand.
- Keep the target-version header comment in sync with the snapshot.

## Editing the zsh tooling (tests/, tools/)

- Unquoted `$c` does not word-split in zsh. Use `${=c}` when a variable holds a multi-word command path.
- Never declare a local named `path`; zsh ties it to `PATH` and wipes command lookup for the whole dynamic scope.
- The local `grep` may be ugrep, which fails on the bundle's long lines. Mine `index.js` with perl or `/usr/bin/grep`.
- `tools/cli-surface.txt` is generated: never hand-edit it, regenerate it with `zsh tools/check-drift.zsh snapshot`.

## Hazards

Never execute `agent`, not even `--help`: every invocation reaches the network, an unknown first word starts a session, and `persist attach --help` treats the flag as a session name. Only `tools/check-drift.zsh` may run it, through `run_isolated` and `guard_argv`, which are never loosened. Full hazards: CONTRIBUTING.md.

## Updating for a new CLI release

Follow "Release process" in CONTRIBUTING.md.

## Style

- Commit subjects are imperative and capitalized, no conventional-commit prefix (`Add ...`, `Fix ...`, `Update _cursor-agent for CLI 2026.10.16-e3cb207`).
- Prose follows the Style section in CONTRIBUTING.md.
