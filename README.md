# Zsh Completion for the Cursor CLI

A static Zsh completion script for the [Cursor CLI](https://cursor.com/docs/cli) (`agent` and `cursor-agent`).

## Status

Scaffold only. The completion surface is not implemented yet: [`src/_cursor-agent`](src/_cursor-agent) is a minimal stub. The target is Cursor CLI 2026.10.01-e373342.

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

## Testing

```bash
zsh tests/run-tests.zsh                   # golden-file suite
zsh tests/zcomp-runner.zsh 'agent '       # print candidates for one buffer
```

The tests never invoke the `agent` binary.

## License

MIT. See [LICENSE](LICENSE).
