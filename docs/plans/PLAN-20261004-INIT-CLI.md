# Plan: Zsh completion for the Cursor CLI (`agent`)

> **Handoff pointer (2026-10-04):** Steps 1 to 4 are done on `claude/inspiring-ptolemy-9usvnc`, and the full `zsh tests/run-tests.zsh` suite passes (307 cases). Next is step 5 (docs and release). Verification items 2, 5 and 7 remain because they execute the CLI or need a person. Never run `agent`; use `CHECK_DRIFT_CACHE=<dir>` if the drift tool is needed. Open questions for the owner: (1) No spec declares the `=` form, so `agent --mode=` completes nothing although commander accepts `--mode=plan`. (2) After optional-value options (`agent --resume `, `agent -w `) the command roster is offered, although commander would take the next word as the value. (3) `tests/run-tests.zsh` rejects a case with no expected candidates, so "offers nothing" cannot be pinned.


## Context

The Cursor CLI ships no shell completion (no `completion` command, no `_agent` file anywhere in `$fpath`). The goal is a static, comprehensive Zsh completion script for it, built as a sibling of the Claude Code completion project at `/Users/vyluong/Development/claude/custom/claude-code-completion/` and following the same policy: everything the binary accepts is completed, including what `--help` hides, and every hidden entry carries provenance.

The target directory `/Users/vyluong/Development/cursor/custom/cursor-completion/` is empty and not a git repo.

### What exploration established (installed CLI 2026.10.01-e373342)

- `agent` and `cursor-agent` in `~/.local/bin` both symlink to `~/.local/share/cursor-agent/versions/<version>/cursor-agent`, a bash wrapper that runs a bundled Node on `index.js` (8 MB webpack bundle plus lazy chunks). This is not a single native binary, so the reference project's `strings`-based miner does not carry over; mining greps `index.js` directly.
- Parser is stock commander 14, no `enablePositionalOptions`. Registrations live in module `./src/cli.ts` as explicit chains on named variables, so attaching options to commands is reliable.
- Surface, in four tiers:
  1. **Visible**: 30 root options, 20 root commands, nested `mcp`, `plugin marketplace`, `team`, `bedrock`, `worker` (`start`, `controller`, `debug`).
  2. **Hidden, registered** (`.hideHelp()` / `{hidden:!0}`): about 40 root options (`--debug`, `--auth-token`, `--image`, `--allowed-tools`, `-c/--cloud`, ...), 2 worker options, and commands `record`, `shell-integration`, `repo`, `local-worker`, `worker-server`, `worker self-test`, `acp`, `install`, `cleanup-install-versions`, `upgrade`, `set-channel`, `get-channel`, `repaint-debug`, `sandbox` (`enable|disable|reset|run`), model shortcuts `opus|sonnet|gpt5|gpt-5`, `bedrock use-team-role`.
  3. **Feature-gated** (Statsig, account-dependent, not registered on this machine): `automations`, `cloud`, `env` with their subtrees. Known from static mining only.
  4. **Dev-only, compiled out** (`I.Cu` is `false`): `dev`, `dev-login`, `--ian-dev`, etc. Not invokable.
- `persist` is hand-rolled and runs before commander (`list`, `attach <session>`, `stop <session>`, or `[options] [prompt...]`).
- Runtime-only values (never hard-code): models, team names, MCP identifiers, chat IDs, saved workspaces, persist sessions, marketplaces.
- Hazards for anything that executes the CLI: every invocation (even `--help`) does a DNS lookup of `api2.cursor.sh` and may warm Statsig; `agent persist attach --help` and `persist stop --help` treat `--help` as a session name; an unknown first word is a prompt and starts a real session; in zsh, multi-word command paths need `${=c}`.

## Decisions

- **File and names**: `src/_cursor-agent` with `#compdef agent cursor-agent`. The file name avoids colliding with any other tool's `_agent`; helpers are `_cursor_agent_*`. `cursor` is not claimed (it is the IDE's shim).
- **Scope**: tiers 1 to 3 are completed; tier 4 is excluded because the binary cannot execute it. Tier 3 goes in its own clearly labelled block and `_describe` tag (`gated-commands`), with comments stating it is gate-dependent and statically mined only, so it is removable in one edit.
- **Fully static**: the script never runs `agent`, never reads `.cursor/mcp.json`, chat stores, or any other local state, uses no `eval`, and forks no subprocesses. Runtime-only values get a descriptive message and no candidates (`--model` hints at `agent --list-models`). Secret-bearing options (`--api-key`, `--auth-token`, `--local-agent-api-key`, `bedrock configure --access-key/--secret-key`) complete nothing.
- **Leaf contexts complete leaf options only.** Commander would also accept root options after a subcommand, but offering 70 root flags under `agent mcp list` is noise; this is recorded as a deliberate choice in a comment. Before a subcommand, and after a first word that is not a command (the prompt case), root options stay available.

## Implementation steps

### 1. Scaffold the project (mirror the reference layout)

```
src/_cursor-agent
tests/zcomp-runner.zsh   tests/run-tests.zsh   tests/cases/*.txt
tools/check-drift.zsh    tools/cli-surface.txt (generated)
tools/check-coverage.zsh tools/coverage-exceptions.txt
README.md  CLAUDE.md  CHANGELOG.md  LICENSE (MIT)  .github/workflows/ci.yml
```

- `git init` on `main`; commit style per the reference (imperative, capitalized subjects).
- Port `tests/zcomp-runner.zsh` and `tests/run-tests.zsh` from the reference nearly verbatim (zpty harness with `compadd`/`_message` capture, golden files with `exact`/`contains` modes and `# double-tab`). Only the script name, fpath copy, and default buffer prefix change.
- Port `ci.yml` (syntax job with `zsh -n`, test matrix ubuntu + macos), `LICENSE`, and the CLAUDE.md conventions (hidden-entry provenance rule, inline brace pairs, no local named `path`, `${=c}`, generated snapshot never hand-edited). Prose in American English, no default em dashes.

### 2. Build the drift tool first: `tools/check-drift.zsh`

Adapted from the reference's `tools/check-drift.zsh` (modes `check` / `snapshot` / `dump`; exit 0/1/2; sorted `LC_ALL=C` snapshot in `tools/cli-surface.txt`). It is the only thing that executes the CLI, and it produces the ground truth the script is written from.

- **Locate**: resolve `command -v agent` through symlinks (`:A:h`) to the version directory; record the version from the directory name and `--version`.
- **Mine `index.js`** with perl and `/usr/bin/grep` (the local `grep` is ugrep and fails on long lines). Slice the `./src/cli.ts` module and emit an ordered token stream: `.command(...)` with `{hidden:!0}` / `isDefault`, `.alias(es)`, `.option` / `.requiredOption`, `new <Ident>("<spec>"...)` option objects with paren-balanced detection of `.hideHelp()`, `.choices`, `.default`, `.preset`, `.env`, `.conflicts`, `.argument`, plus markers for feature gates and the dev-only guard. Match identifiers generically; minified names (`wt`, `h.c$`) change per build. Also mine `persistent-session.ts` (persist grammar), `worker-pool.ts` (`--pool` rewrite), the `--output-format` validator, and the channel/shell enums.
- **Help walk**: recursive from the root over every child that help or the miner reports (see "Updating for future CLI releases"), each run as `agent ${=c} --help` with `</dev/null`, a wall-clock cap that reaps children, and a guard that the output starts with that command's own `Usage:` line (root-help fallback means "not registered"). Denylist: `persist attach` and `persist stop`.
- **Probes** (the validation of hidden surface):
  - Command: own usage line in `--help` output means invokable.
  - Value-taking option: run with the value missing; `argument missing` means recognized, `unknown option` means not.
  - Boolean option: `agent <path> --flag --zz-bogus`; commander reports the first unknown option, so an error naming `--zz-bogus` proves `--flag` is known. Before enabling this, confirm in the bundle that the unknown-option error precedes every action and hook. Flags pre-scanned from raw argv (`--statsig-overrides`, `--disable-project-configs`, `--authless`, `--enable-bedrock`, `--enable-local-bedrock`) and everything under `persist` are never probed and are recorded as "static only".
  - Never run a line that could parse cleanly (no bare booleans, no positional words).
- **Isolation**: run every invocation with a throwaway `HOME` and `CURSOR_CONFIG_DIR` and a scrubbed environment (no `CURSOR_*` / `AGENT_CLI_*`), so results do not depend on the local account, gates, or config, and nothing in the real `~/.cursor` is touched.

Cross-check the dump against the official CLI docs (cursor.com/docs/cli) as a secondary reference only; the binary wins every disagreement, and discrepancies are noted in comments.

### 3. Write `src/_cursor-agent` from the snapshot

Same structure as the reference `src/_claude`: one `_arguments -C` dispatcher, `_describe` rosters, one function per command path, header comment with target version and capture date.

- **Root**: `global_options` array with visible options first, then labelled hidden groups (user-facing, internal/endpoint/dev, deprecated), each hidden entry with provenance (mined spec, probe result, date, version). Exclusions for `-f/--force/--yolo`, `--mode`/`--plan`, `--resume`/`--continue`, deprecated `-c/-b`. Repeatables with `*` (`-H`, `--add-dir`, `--plugin-dir`, `--image`, `--allowed-tools`, `--exclude-tools`). Optional values with `::` (`--resume`, `-w/--worktree`). Enums inline: `--mode`, `--sandbox`, `--output-format`, `--computer-use-coords`, `--http-version`. Paths via `_files` / `_directories`.
- **Dispatch**: `1: :_cursor_agent_commands`, `*:: :->args`; the `*)` fallback (first word was a prompt) re-offers root options with a free-text prompt argument. The root call uses `-A '-*'` so that an option typed after a command word reaches the leaf's own table, and the prompt fallback re-offers root options itself.
- **Rosters**: three `_describe` groups: `commands`, `hidden-commands`, `gated-commands`. Aliases included (`whoami`, `rule`, `upgrade`).
- **Leaves**: `mcp` (5), `plugin marketplace` (4, `add --git-ref`), `team` (`list`, `switch [team]`), `bedrock` (6 plus hidden `use-team-role`), `worker` (about 25 options, `--share-desktop` enum, `--pool` optional value, hidden `--worker-api-socket`/`--worker-id`; `start`, `controller` with its conflict sets, `debug`, hidden `self-test`), `status|whoami|about --format`, `persist` (`list|attach|stop` or root options plus prompt), `help [command]` at each level that has it (completes that level's command names), `sandbox run`, `repo`, `local-worker`, `set-channel` (4 channels), `shell-integration` (`zsh`), `install`, model shortcuts, and the gated `automations` / `cloud` / `env` trees with their enums.

### 4. Tests

One golden case per command roster, per leaf's flags, per enum, plus prefix filtering, the prompt-fallback case, `help` completion, and negative cases (secret options and `--model` yield a message, no candidates). Expectations are generated with `zcomp-runner.zsh`, then reviewed against `tools/cli-surface.txt`, never hand-typed. The suite never invokes `agent`.

### 5. Docs and release

README (install into a user completions dir before `compinit`, cache clear, usage, note on the `agent()` function that `install-shell-integration` defines, which `compdef` still covers), CLAUDE.md, CHANGELOG with the release process, tag `cli-2026.10.01-e373342`.

## Updating for future CLI releases (design requirements)

The goal: a CLI update is handled by running two commands and editing only the lines they point at, with no re-audit of the bundle or the script.

1. **Self-validating miner.** The miner depends on minified bundle shapes, so it must fail loudly instead of reporting "no drift" when a build changes them. On every run `check-drift.zsh` asserts: the `./src/cli.ts` module was found; the mined visible surface equals the help-walk surface exactly (two independent sources); anchor entries (`--print`, `mcp`, `worker`) are present. Any mismatch exits 2 with "miner needs attention", naming the disagreeing entries.
2. **Recursive discovery, not a fixed roster.** The help walk starts at the root and follows every child that help or the miner reports, with a small denylist for unsafe paths (`persist attach`, `persist stop`). New commands and subtrees are picked up without editing the tool.
3. **Automatic tiering.** The miner tags each entry `visible`, `hidden`, `gated:<gate-name>`, or `dev-only`, and probes classify themselves (value-taking: missing-argument probe; boolean: trailing-bogus probe; pre-scanned or under `persist`: static only). A new flag needs no manual decision about how to verify it.
4. **Actionable drift report.** `check` prints added / removed / changed lines grouped by command path. Function names derive mechanically from the path (`agent plugin marketplace add` is `_cursor_agent_plugin_marketplace_add`), so each drift line names the function to edit.
5. **Mechanical coverage check: `tools/check-coverage.zsh`.** Parses the `_arguments` specs and `_describe` rosters out of `src/_cursor-agent` per function and compares them, both directions, with the committed `tools/cli-surface.txt`: option names, aliases, value-taking vs boolean, optional vs required value, enum values, subcommand names, hidden/gated grouping. Deliberate deviations live in `tools/coverage-exceptions.txt`, one line each with a reason. It needs no binary, so it runs in CI and in `run-tests.zsh` preflight. This replaces manual verification step 3 and is what removes the need for a full audit: snapshot drift says what changed in the CLI, coverage says what the script still lacks.
6. **Version-addressable.** `check-drift.zsh --version-dir <path>` targets any installed version directory, and `diff <old> <new>` compares two, so an update can be previewed and regressions bisected using the side-by-side installs.
7. **Low-churn provenance.** Per-entry probe results, dates, and versions live in the generated snapshot. Script comments only say that an entry is hidden or gated and how that class is verified; the header carries the single target version. An update then touches changed entries only, not every comment.
8. **Runbook** in CLAUDE.md and CHANGELOG: `agent update`; `check-drift.zsh` (fix the miner first if it exits 2); `check-drift.zsh snapshot`; `check-coverage.zsh` and edit the functions it lists; regenerate affected test cases with `zcomp-runner.zsh`; `run-tests.zsh`; bump header; CHANGELOG section; tag.

What still needs human judgment on an update: descriptions and value completers for new options (file vs directory vs free text), mutual-exclusion groups, and repairing the miner when exit 2 fires. Full generation of the script from the snapshot was considered and rejected for that reason; the coverage check gives the same completeness guarantee while keeping the script hand-readable.

## Verification

1. `zsh -n` on the script and all tooling.
2. `zsh tools/check-drift.zsh snapshot`, then `check` exits 0; every probe of a hidden entry in the script shows "recognized", and `unwalked` is empty.
3. `zsh tools/check-coverage.zsh` exits 0 (script and snapshot agree in both directions; exceptions file reviewed). Sanity-test the checker itself by deleting one option and one enum value from a scratch copy of the script and confirming both are reported.
4. `zsh tests/run-tests.zsh` passes in full.
5. Manual: install into a temp fpath in a clean `zsh -f` session and tab through `agent `, `agent --`, `agent mcp `, `agent worker --share-desktop `, `cursor-agent `.
6. Static audit of the script: no command substitution, `eval`, file reads, or references to `$HOME`/`~/.cursor`; time a completion to confirm it is instant.
7. Rehearse an update: `check-drift.zsh diff` between the installed 2026.09.23 and current version directories must report exactly one addition (`--session-token`), and pointing the tool at the old version must make `check-coverage.zsh` name that one option and its function.
