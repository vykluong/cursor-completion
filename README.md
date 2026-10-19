# Zsh Completion for the Cursor CLI

[![CI](https://github.com/vykluong/cursor-completion/actions/workflows/ci.yml/badge.svg)](https://github.com/vykluong/cursor-completion/actions/workflows/ci.yml)

A [static](CONTRIBUTING.md#design-policy) Zsh completion script for the [Cursor CLI](https://cursor.com/docs/cli), covering both of its command names, `agent` and `cursor-agent`. It completes every visible and hidden command and option, with a few [deliberate exceptions](CONTRIBUTING.md#design-policy), plus the [feature-gated](CONTRIBUTING.md#scope-the-four-surface-tiers) `automations`, `cloud`, and `env` trees.

Generated against Cursor CLI 2026.10.16-e3cb207.

## Install

Download the script into a completions directory and add that directory to `fpath`:

```bash
mkdir -p ~/.zsh/completions
curl -fsSL -o ~/.zsh/completions/_cursor-agent \
  https://raw.githubusercontent.com/vykluong/cursor-completion/main/src/_cursor-agent

# in ~/.zshrc, BEFORE compinit:
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit
```

Alternatively, on Homebrew, drop the file into Homebrew's `site-functions` directory. It is already on `fpath` when you use Homebrew's zsh; with the macOS system zsh, add that directory to `fpath` before `compinit` as in the first block.

```bash
curl -fsSL -o "$(brew --prefix)/share/zsh/site-functions/_cursor-agent" \
  https://raw.githubusercontent.com/vykluong/cursor-completion/main/src/_cursor-agent
```

You can also clone the repository and copy `src/_cursor-agent` into either location.

## Try it

`agent <TAB>` (with a trailing space) lists every top-level command, and `cursor-agent <TAB>` behaves the same.

`agent mcp l<TAB>` narrows the list to what is valid there:

```
list
list-tools
login
```

`agent --mode <TAB>` completes the enum values:

```
ask
plan
```

`agent --model <TAB>` shows a hint instead of candidates, since models depend on your account:

```
model name (run agent --list-models to see them)
```

## Troubleshooting

If `agent <TAB>` completes nothing after installing, the cause is usually a stale completion cache:

```bash
rm -f ~/.zcompdump*
exec zsh
```

Completion keeps working after the CLI's `install-shell-integration` defines an `agent` shell function, because `compdef` binds by command name.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the design policy, tests, tooling, and release process. Changes per CLI release are recorded in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
