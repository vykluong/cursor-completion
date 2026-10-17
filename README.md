# Zsh Completion for the Cursor CLI

[![CI](https://github.com/vykluong/cursor-completion/actions/workflows/ci.yml/badge.svg)](https://github.com/vykluong/cursor-completion/actions/workflows/ci.yml)

A static Zsh completion script for the [Cursor CLI](https://cursor.com/docs/cli), covering both of its command names, `agent` and `cursor-agent`.

Generated against Cursor CLI 2026.10.16-e3cb207.

## What it completes

[`src/_cursor-agent`](src/_cursor-agent) (`#compdef agent cursor-agent`) completes commands, subcommands, options, and enum values. Its tables are written from [`tools/cli-surface.txt`](tools/cli-surface.txt), a snapshot generated from the installed CLI. The CLI's surface falls into four tiers:

1. **Visible in `--help`**: completed.
2. **Hidden but registered** (commands and options the CLI accepts but `--help` does not list, such as `shell-integration` or `--repo-endpoint`): completed.
3. **Feature-gated** (account-dependent: `automations`, `cloud`, `env`): completed, in their own labelled block and `gated-commands` tag. These are known from static mining of the CLI bundle only, so they may not be available on your account.
4. **Dev-only** (compiled out of release builds, such as `dev`, `dev-login`, `--ian-dev`): excluded, since the binary cannot execute them.

`cursor`, the Cursor IDE's shell command, is deliberately not claimed.

### Design policy

- **Fully static.** The script never runs `agent`, reads no local state (no `.cursor/mcp.json`, chat stores, or config), uses no `eval`, and forks no subprocesses. Completion stays fast and has no side effects.
- **Runtime-only values get a hint, not candidates.** Models, teams, MCP identifiers, chat IDs, workspaces, persist sessions, and marketplaces depend on your account and machine, so the script shows a descriptive message instead (for `--model`, it points at `agent --list-models`).
- **Secrets complete nothing.** `--api-key`, `--auth-token`, `--local-agent-api-key`, and `bedrock configure --access-key`/`--secret-key` offer no candidates.
- **Leaf contexts complete leaf options only.** The CLI also accepts root options after a subcommand, but offering every root flag under `agent mcp list` is noise. Before a subcommand, and after a first word that is not a command (a prompt), root options stay available.
- **Space-separated values only.** Values complete as `--mode plan`, not `--mode=plan`, matching the CLI's own usage hints.
- **No commands after an optional-value option.** After `--resume`, `-w`/`--worktree`, or a bare worker `--pool`, the CLI takes the next word as the value, so no commands are offered there (except the words that end a worker `--pool`).

## Install manually

`src/_cursor-agent` is a standard Zsh completion script, installed like any other:

```bash
mkdir -p ~/.zsh/completions
cp src/_cursor-agent ~/.zsh/completions/

# in ~/.zshrc, BEFORE compinit:
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit
```

### Clear cache

If `agent <TAB>` completes nothing afterwards, the cause is usually a stale completion cache:

```bash
rm -f ~/.zcompdump*
exec zsh
```

### Shell integration

The CLI's `install-shell-integration` command (removed again by `uninstall-shell-integration`) defines an `agent` shell function in `~/.zshrc`. Completion keeps working: `compdef` binds by command name, so zsh completes a function named `agent` with the same `_cursor-agent` function.

## Usage

### Command discovery

Press TAB after `agent ` (with a trailing space) to list every top-level command, hidden and gated ones included. `cursor-agent ` behaves the same.

### Context-aware completion

Press TAB partway through a command to narrow the list to what is valid there. `agent mcp l<TAB>` offers:

```
list
list-tools
login
```

### Option values

Enum values complete directly. `agent --mode <TAB>` offers `ask` and `plan`, and `agent shell-integration <TAB>` offers `zsh`.

Runtime-only values show a hint instead. `agent --model <TAB>` shows `model name (run agent --list-models to see them)`, and `agent mcp enable <TAB>` shows `MCP server identifier (run agent mcp list to see them)`.

### Option discovery

Press TAB after `-` to list the options of the current command. At a leaf, only that command's own options appear: `agent mcp list -<TAB>` offers `-h` and `--help`.

## Testing

```bash
zsh tests/run-tests.zsh                       # golden-file suite (CI runs it on ubuntu and macos)
zsh tests/run-tests.zsh 'mcp-*'               # subset, glob on case name
zsh tests/zcomp-runner.zsh 'agent mcp '       # print candidates for one buffer
DOUBLE_TAB=1 zsh tests/zcomp-runner.zsh 'agent '   # simulate a second TAB
```

The harness drives a real interactive zsh through `zpty` and never invokes the `agent` binary. Each file in `tests/cases/` holds one buffer and its expected candidates; the format is documented at the top of [`tests/run-tests.zsh`](tests/run-tests.zsh). Before any case runs, the suite checks the script with `zsh -n` and runs the coverage check below.

## Maintenance

- [`tools/check-coverage.zsh`](tools/check-coverage.zsh) compares `src/_cursor-agent` with the snapshot in both directions. It needs no CLI. Deliberate deviations are listed, with reasons, in [`tools/coverage-exceptions.txt`](tools/coverage-exceptions.txt).
- [`tools/check-drift.zsh`](tools/check-drift.zsh) diffs the installed CLI against `tools/cli-surface.txt` (exit 1 on drift), and `zsh tools/check-drift.zsh snapshot` accepts a new surface. It is the only part of the project that executes the CLI, in isolated throwaway directories, and CI never runs it. `zsh tools/check-drift.zsh diff <old-version-dir> <new-version-dir>` previews an update statically, and `--help` lists all modes and exit codes.

The update runbook for a new CLI release is in [CHANGELOG.md](CHANGELOG.md) (Release process) and [CLAUDE.md](CLAUDE.md), along with the hazards of executing the CLI.

## License

MIT. See [LICENSE](LICENSE).
