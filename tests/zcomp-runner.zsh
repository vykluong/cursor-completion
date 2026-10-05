#!/usr/bin/env zsh
# Capture the completion candidates _cursor-agent offers for a given buffer.
# Usage:  zsh tests/zcomp-runner.zsh 'agent '           # single TAB (default)
#         DOUBLE_TAB=1 zsh tests/zcomp-runner.zsh 'agent '   # press TAB twice
# Output: sorted unique candidates, one per line. `_message` hints print as "MSG: <text>".
# Exit: 0 when _cursor-agent was loaded, ran for the buffer, and returned
# without a shell error (status 0 or 1); 3 otherwise (script failed to load,
# prompt timed out, or the buffer never reached _cursor-agent). Empty output
# with exit 0 means the completion really offered nothing.
set -u
BUF=$1
REPO=${0:A:h:h}
WORK=$(mktemp -d)
LOG=$WORK/cap.log
RANLOG=$WORK/ran.log
mkdir -p $WORK/home
# Complete from a private copy of the script: CI checkouts can be
# group-writable, and compaudit strips such dirs from fpath even under
# `compinit -u`, which would silently unregister _cursor-agent.
mkdir -p $WORK/fns
cp $REPO/src/_cursor-agent $WORK/fns/
# Ubuntu's /etc/zsh/zshrc runs a bare `compinit` before ZDOTDIR/.zshrc; on CI
# runners with group-writable system dirs it blocks on the interactive
# "insecure directories" prompt, so the ZC> prompt never appears. Skipping the
# global compinit is harmless on other platforms.
print -r -- 'skip_global_compinit=1' > $WORK/home/.zshenv
cat > $WORK/home/.zshrc <<EOF
fpath=($WORK/fns \$fpath)
autoload -U compinit
compinit -u -d $WORK/home/zcompdump
compadd() { local -a m; builtin compadd -O m "\$@" 2>/dev/null; (( \$#m )) && print -rl -- "\$m[@]" >> \$CAPLOG; builtin compadd "\$@"; }
_message() { print -r -- "MSG: \$*" >> \$CAPLOG }
# Run marker: _cursor-agent is dispatched through this wrapper, which appends
# "ran" to \$RANLOG only if the script loaded and returned cleanly.
_zc_probe() {
  local -i _zc_st=2
  {
    autoload +X _cursor-agent && { _cursor-agent "\$@"; _zc_st=\$? }
  } always {
    (( TRY_BLOCK_ERROR == 0 && _zc_st <= 1 )) && print -r -- ran >> \$RANLOG
  }
  return _zc_st
}
compdef _zc_probe agent cursor-agent
unset zle_bracketed_paste
PS1='ZC> '
EOF
zmodload zsh/zpty

wait_prompt() {
  local chunk out="" i=0
  while (( i++ < 50 )); do
    sleep 0.1
    while zpty -r -t Z chunk 2>/dev/null; do out+=$chunk; done
    [[ $out == *"ZC>"* ]] && return 0
  done
  return 1
}

attempt() {
  : > $LOG
  : > $RANLOG
  zpty -b Z "TERM=xterm ZDOTDIR=$WORK/home CAPLOG=$LOG RANLOG=$RANLOG zsh -i"
  wait_prompt || { zpty -d Z 2>/dev/null; return 1 }
  local chunk
  zpty -n -w Z $'\n'
  wait_prompt
  zpty -n -w Z "$BUF"
  sleep 0.3
  zpty -n -w Z $'\t'
  sleep 1
  if [[ ${DOUBLE_TAB:-0} == 1 ]]; then
    zpty -n -w Z $'\t'
    sleep 1
  fi
  while zpty -r -t Z chunk 2>/dev/null; do :; done
  zpty -d Z 2>/dev/null
}

for i in {1..8}; do
  attempt
  [[ -s $LOG || -s $RANLOG ]] && break
done
sort -u $LOG
integer rc=3
[[ -s $RANLOG ]] && rc=0
rm -rf $WORK
exit $rc
