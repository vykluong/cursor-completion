#!/usr/bin/env zsh
#
# check-drift.zsh: detect drift between the installed Cursor CLI (`agent`) and
# the CLI surface that this repo's completion script (src/_cursor-agent) is
# written against, recorded in tools/cli-surface.txt.
#
# MAINTAINERS: rerun `zsh tools/check-drift.zsh` after every `agent update`
# (full runbook in CLAUDE.md). Exit 2 with "miner needs attention" means the
# bundle changed shape under the miner: fix the miner before trusting any
# result, never the other way around.
#
# Usage:
#   zsh tools/check-drift.zsh [options] [check]   # default: regenerate + diff, exit 1 on drift
#   zsh tools/check-drift.zsh [options] snapshot  # overwrite tools/cli-surface.txt
#   zsh tools/check-drift.zsh [options] dump      # write the dump to stdout, no diff
#   zsh tools/check-drift.zsh diff <old-version-dir> <new-version-dir>
#
# Options:
#   --version-dir <path>  use this version directory instead of the one `agent`
#                         resolves to (any dir under ~/.local/share/cursor-agent/versions/)
#   --static              mined half only; never execute the CLI
#
# Environment:
#   CHECK_DRIFT_CACHE=<dir>  development aid: record every CLI run under
#                            <dir>/<version>/ and replay it on later runs
#
# Exit codes: 0 = no drift, 1 = drift, 2 = the tool itself could not run (no
# `agent` on PATH, a bad version directory, the miner needs attention, or a
# CLI run did something unexpected).
#
# STATUS: `dump` (mined records, help walk, probes, mined-vs-help validation)
# and `dump --static` work. The check / snapshot / diff modes are stubs that
# exit 2 with "not implemented".
#
# Where the surface comes from. `agent` is not a native binary: it is a bash
# wrapper that runs a bundled Node on a webpack bundle, <version-dir>/index.js,
# plus lazy chunks <version-dir>/<n>.index.js. Every commander registration
# lives in the `./src/cli.ts` module of index.js; the miner slices it out and
# follows each registration chain (`x.command(..).option(..).addOption(new
# O(..).hideHelp())`) to the command it attaches to, including chains bound to
# variables, helper functions that add options to their argument, and
# functions that register one command per call site. Side modules:
#   ./src/persistence/persistent-session.ts  `persist`, parsed before commander
#   ./src/commands/worker-pool.ts            the `worker --pool` argv rewrite
#   ./src/utils/output-format.ts             the `--output-format` validator
#   ../cursor-config/dist/schema.js          `set-channel` channel values
#   ./src/commands/shell-integration.ts      `shell-integration` shell values
#   ./src/constants.ts, ./src/statsig.ts     the dev-only guard, feature gates
# Module paths are stable source names; minified identifiers change every
# build, so none is matched by name: import aliases are read from the module's
# own require calls, and local identifiers resolve to the definition in the
# innermost enclosing scope.
#
# Record format: one record per line, LC_ALL=C sorted, fields joined by " | ":
#
#   <kind> | <command path> | <name> | <tier> [| <attribute>]...
#
# The first three fields are the entry's key; later stages (help walk,
# probes) append attributes without changing it. Paths start with `agent`.
# The completion function for a path is `_cursor_agent` plus the words after
# `agent`, joined with `_`, with `-` mapped to `_` (`agent plugin marketplace
# add` -> _cursor_agent_plugin_marketplace_add); see path_function below.
#
#   cmd      <path> is the parent, <name> the subcommand (a roster entry)
#   arg      a positional argument of <path>; <name> is its spec: <x> [x] [x...]
#   opt      an option of <path>; <name> is the full spec, `-e, --endpoint <url>`
#   enum     values that a validator outside commander accepts for <name>
#   grammar  hand-rolled argv handling: `persist` usage, subcommands and help
#            flags; the `worker --pool` rewrite (value for a bare --pool, words
#            that end it, flags it moves)
#   prescan  a flag read from raw argv before commander that has no option
#            registration (registered ones carry the `prescan` attribute)
#   meta     version (from the directory name), source module, bundle version
#
# Tiers (the effective class, inherited from the parent command):
#   visible      registered, and listed by the parent's --help
#   hidden       registered, but `{hidden:!0}` / `.hideHelp()` on it or a parent
#   gated:<g>    registered only when Statsig gate(s) pass: `a||b` is the
#                guard expression with gate names substituted, `+` joins
#                nested guards (all must pass)
#   dev-only     guarded by a constant that is false in ./src/constants.ts
#                (compiled out of release builds; not invokable)
#   static       meta and prescan records (no commander registration)
#
# Attributes (`?` is a value that is not a static literal; values containing
# spaces, commas, `|`, `"` or `=` are double-quoted):
#   hidden, hidden=cond   the entry's own hidden flag (cond: a runtime value)
#   conditional           registered behind a runtime condition that is
#                         neither a gate nor dev-only (e.g. not in local mode)
#   builtin               commander's implicit `help` command or -h/--help
#   cmd:  aliases=a,b  default-command  subcommands  action  allowExcessArguments=..
#         allowUnknownOption=..  passThroughOptions=..  enablePositionalOptions=..
#   arg:  pos=<n>  required|optional  variadic
#   opt:  value=none|required|optional  variadic  mandatory  repeatable (an
#         accumulating parser)  parser (any other custom parser)  choices=a,b
#         default=v  preset=v  env=VAR  conflicts=--flag,..  implies  prescan
#   enum: values=a,b  source=validator|config-schema
#
# Without --static, the help walk and the probes append (see run_probes):
#   help-listed | probe=recognized|unknown | static-only=<why>   on every
#                         record but meta; probe-value=none|required (and
#                         unknown-flags=..) on probed options
#   walk=own-usage|fallback | not-walked=<why>   on cmd records
#
# Every execution of `agent` goes through run_isolated (see the hazards in
# CLAUDE.md).

emulate -L zsh
setopt extended_glob no_unset pipe_fail
export LC_ALL=C

# Capture at file scope: inside a function, $0 is the function's name.
typeset -g SCRIPT_PATH=${0:A}
typeset -g SNAPSHOT=${SCRIPT_PATH:h}/cli-surface.txt

typeset -g OPT_VERSION_DIR='' VERSION_DIR='' VERSION=''
typeset -gi STATIC_ONLY=0

typeset -ga _TMPFILES=() _TMPDIRS=()

_cleanup() {
  (( ${#_TMPFILES} )) && rm -f -- "${_TMPFILES[@]}"
  (( ${#_TMPDIRS} )) && rm -rf -- "${_TMPDIRS[@]}"
  _TMPFILES=() _TMPDIRS=()
  return 0
}
trap _cleanup EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

die() { print -ru2 -- "check-drift: $*"; exit 2 }

# Sets $REPLY to a fresh temp file, registered for cleanup on any exit.
# `REPLY=$(mktemp)` keeps the assignment in the current shell; a `$(...)`
# wrapper around the whole helper would lose the _TMPFILES append to a subshell.
new_tmpfile() {
  REPLY=$(mktemp) || die "mktemp failed"
  _TMPFILES+=("$REPLY")
}

# NOTE: never name a local `path` in this file. zsh ties `path` to `PATH`, so a
# `local path=...` silently wipes the command search path for that function's
# whole dynamic scope. Use `cmdpath`.
#
# zsh gotcha for the execution half: unquoted $c does NOT word-split in zsh, so
# `agent $c --help` with c="mcp list" runs `agent "mcp list" --help`, which is a
# prompt, not a subcommand. Always use ${=c}.

# Completion function name for a command path:
# `agent plugin marketplace add` -> _cursor_agent_plugin_marketplace_add.
path_function() {
  local cmdpath=${1#agent}
  cmdpath=${${cmdpath##[[:space:]]##}//-/_}
  print -r -- "_cursor_agent${cmdpath:+_${cmdpath// /_}}"
}

# ---------------------------------------------------------------------------
# Locate the version directory
# ---------------------------------------------------------------------------

# Sets VERSION_DIR and VERSION. `agent` (and `cursor-agent`) in ~/.local/bin
# are symlinks to <version-dir>/cursor-agent, so the resolved path's directory
# is the version directory and its name is the version. `whence -p` skips the
# `agent` shell function that `install-shell-integration` defines.
locate_version_dir() {
  local dir bin
  if [[ -n $OPT_VERSION_DIR ]]; then
    dir=${OPT_VERSION_DIR:A}
  else
    bin=$(whence -p agent) || die "no 'agent' on PATH (or pass --version-dir <path>)"
    dir=${bin:A:h}
  fi
  [[ -d $dir ]] || die "version directory $dir does not exist"
  [[ -r $dir/index.js ]] || die "$dir has no index.js; not a Cursor CLI version directory"
  VERSION_DIR=$dir
  VERSION=${dir:t}
}

# ---------------------------------------------------------------------------
# Static half: the index.js miner
# ---------------------------------------------------------------------------

# The miner is perl (the bundle's lines run to megabytes; the local `grep` may
# be ugrep, which fails on them). It reads the version directory given as its
# argument, prints unsorted records, and exits 2 with "miner needs attention:
# <reason>" on stderr when the bundle no longer has the shape it expects:
# a required module or anchor entry (--print, mcp, worker) is missing, a
# registration call cannot be attributed to a command, or a side-module value
# no longer resolves to a literal.
write_miner() {
  cat <<'PERL'
use strict;
use warnings;

# ---------------------------------------------------------------------------
# Bundle access
# ---------------------------------------------------------------------------

my $VDIR = shift @ARGV;
my @FILES = ("$VDIR/index.js", sort glob("$VDIR/*.index.js"));
my %TEXT;

sub need {
  print STDERR "check-drift: miner needs attention: $_[0]\n";
  exit 2;
}

sub file_text {
  my $f = shift;
  return $TEXT{$f} if exists $TEXT{$f};
  open my $fh, '<', $f or need("cannot read $f");
  local $/;
  $TEXT{$f} = <$fh>;
  close $fh;
  return $TEXT{$f};
}

# Body of webpack module NAME, from its `"NAME"(a,b,c){` key up to the next
# module key. Searches index.js first, then the lazy chunks. Returns
# (text, file name) or an empty list.
sub find_module {
  my $want = shift;
  my $key = "\"$want\"(";
  for my $f (@FILES) {
    my $t = file_text($f);
    my $i = index($t, $key);
    next if $i < 0;
    pos($t) = $i + length $key;
    my $e = $t =~ /\},"[^"]+"\([\w\$]*(?:,[\w\$]+)*\)\{/g ? $-[0] : length $t;
    (my $base = $f) =~ s{.*/}{};
    return (substr($t, $i, $e - $i), $base);
  }
  return;
}

# ---------------------------------------------------------------------------
# Minimal JS scanning: strings, templates, regex literals, bracket matching.
# All positions are indexes into the string behind the reference $sr.
# ---------------------------------------------------------------------------

my %OPENER = ('(' => 1, '[' => 1, '{' => 1);
my %REGEX_KW = map { $_ => 1 }
  qw(return typeof case in of void delete throw new else do instanceof yield await);

# Index of the closing quote of the string literal opened at $i.
sub str_end {
  my ($sr, $i) = @_;
  my $q = substr($$sr, $i, 1);
  my $n = length $$sr;
  for (my $j = $i + 1; $j < $n; $j++) {
    my $c = substr($$sr, $j, 1);
    if ($c eq "\\") { $j++; next }
    return $j if $c eq $q;
  }
  return $n - 1;
}

# Does the `/` at $j start a regex literal rather than divide?
sub regex_starts {
  my ($sr, $j) = @_;
  my $k = $j - 1;
  $k-- while $k >= 0 && substr($$sr, $k, 1) =~ /\s/;
  return 1 if $k < 0;
  my $p = substr($$sr, $k, 1);
  if ($p =~ /[\w\$]/) {
    my $e = $k;
    $k-- while $k >= 0 && substr($$sr, $k, 1) =~ /[\w\$]/;
    return $REGEX_KW{substr($$sr, $k + 1, $e - $k)} ? 1 : 0;
  }
  return $p =~ m{[(,=:\[!&|?{};+\-*%<>~^]} ? 1 : 0;
}

sub regex_end {
  my ($sr, $i) = @_;
  my $n = length $$sr;
  my $cls = 0;
  for (my $j = $i + 1; $j < $n; $j++) {
    my $c = substr($$sr, $j, 1);
    if ($c eq "\\") { $j++; next }
    if ($cls) { $cls = 0 if $c eq ']'; next }
    if ($c eq '[') { $cls = 1; next }
    if ($c eq '/') {
      $j++ while $j + 1 < $n && substr($$sr, $j + 1, 1) =~ /[a-z]/;
      return $j;
    }
  }
  return $n - 1;
}

# If a string, template, regex or comment starts at $j, the index of its last
# character; otherwise undef.
sub skip_atom {
  my ($sr, $j) = @_;
  my $c = substr($$sr, $j, 1);
  return str_end($sr, $j) if $c eq '"' || $c eq "'";
  return template_end($sr, $j) if $c eq '`';
  if ($c eq '/') {
    my $d = substr($$sr, $j + 1, 1);
    if ($d eq '/') { my $e = index($$sr, "\n", $j); return $e < 0 ? length($$sr) - 1 : $e }
    if ($d eq '*') { my $e = index($$sr, '*/', $j + 2); return $e < 0 ? length($$sr) - 1 : $e + 1 }
    return regex_end($sr, $j) if regex_starts($sr, $j);
  }
  return undef;
}

sub template_end {
  my ($sr, $i) = @_;
  my $n = length $$sr;
  for (my $j = $i + 1; $j < $n; $j++) {
    my $c = substr($$sr, $j, 1);
    if ($c eq "\\") { $j++; next }
    return $j if $c eq '`';
    if ($c eq '$' && substr($$sr, $j + 1, 1) eq '{') {
      my $e = match_close($sr, $j + 1);
      $j = $e < 0 ? $n : $e;
    }
  }
  return $n - 1;
}

# Index of the bracket matching the opener at $i, or -1.
sub match_close {
  my ($sr, $i) = @_;
  my $depth = 0;
  my $n = length $$sr;
  for (my $j = $i; $j < $n; $j++) {
    my $c = substr($$sr, $j, 1);
    if ($c eq '"' || $c eq "'" || $c eq '`' || $c eq '/') {
      my $e = skip_atom($sr, $j);
      if (defined $e) { $j = $e; next }
      next;
    }
    if ($OPENER{$c}) { $depth++; next }
    if ($c eq ')' || $c eq ']' || $c eq '}') {
      $depth--;
      return $j if $depth == 0;
    }
  }
  return -1;
}

# Split the text of an argument list at top-level commas.
sub split_args {
  my $a = shift;
  my @out;
  my $n = length $a;
  my $start = 0;
  for (my $j = 0; $j < $n; $j++) {
    my $c = substr($a, $j, 1);
    if ($c eq '"' || $c eq "'" || $c eq '`' || $c eq '/') {
      my $e = skip_atom(\$a, $j);
      $j = $e if defined $e;
      next;
    }
    if ($OPENER{$c}) { my $e = match_close(\$a, $j); $j = $e < 0 ? $n : $e; next }
    if ($c eq ',') { push @out, substr($a, $start, $j - $start); $start = $j + 1 }
  }
  push @out, substr($a, $start) if $start < $n;
  s/^\s+|\s+$//g for @out;
  return @out;
}

sub unquote {
  my $s = substr($_[0], 1, -1);
  $s =~ s/\\n/\n/g;
  $s =~ s/\\(.)/$1/g;
  return $s;
}

# ---------------------------------------------------------------------------
# The ./src/cli.ts module and its imports
# ---------------------------------------------------------------------------

my ($S, $CLI_FILE) = find_module('./src/cli.ts');
need("module ./src/cli.ts not found in index.js or any lazy chunk") unless defined $S;
my $SR = \$S;

# Webpack passes the require function as the module's third parameter.
$S =~ /^"\.\/src\/cli\.ts"\(([\w\$]+),([\w\$]+),([\w\$]+)\)\{/
  or need("./src/cli.ts module header has an unexpected shape");
my $REQ = $3;
my %IMPORT;    # alias -> module path
while ($S =~ /(?<![\w\$.])([\w\$]+)=\Q$REQ\E\("([^"]+)"\)/g) { $IMPORT{$1} = $2 }

my ($CMDR) = grep { $IMPORT{$_} =~ m{/commander[^/]*/|commander-js} } sort keys %IMPORT;
need("commander import not found in ./src/cli.ts") unless defined $CMDR;
my ($CONST) = grep { $IMPORT{$_} eq './src/constants.ts' } sort keys %IMPORT;
my ($STATSIG) = grep { $IMPORT{$_} eq './src/statsig.ts' } sort keys %IMPORT;
need("./src/constants.ts import (dev-only guard) not found") unless defined $CONST;
need("./src/statsig.ts import (feature gates) not found") unless defined $STATSIG;

# Exports of a module: export key -> local name, from `r.d(e,{K:()=>L,...})`.
sub module_exports {
  my $m = shift;
  my %x;
  if ($m =~ /\.d\([\w\$]+,\{(.*?)\}\)/s) {
    my $body = $1;
    while ($body =~ /([\w\$]+):\(\)=>([\w\$]+)/g) { $x{$1} = $2 }
  }
  return %x;
}

# Constants that are a literal `!1` / `!0` in ./src/constants.ts. A guard
# on a false constant is compiled out (dev-only); on a true one, a no-op.
my (%DEV_FALSE, %DEV_TRUE);
{
  my ($cm) = find_module('./src/constants.ts');
  need("module ./src/constants.ts not found") unless defined $cm;
  my %x = module_exports($cm);
  for my $k (keys %x) {
    my $l = $x{$k};
    next unless $cm =~ /(?<![\w\$.])\Q$l\E=(!0|!1|true|false)(?![\w\$])/;
    ($1 eq '!1' || $1 eq 'false') ? ($DEV_FALSE{$k} = 1) : ($DEV_TRUE{$k} = 1);
  }
}

# ---------------------------------------------------------------------------
# Literal evaluation and reference resolution
# ---------------------------------------------------------------------------

# Innermost `{...}` block of $$sr that strictly contains $pos, as [start, end].
sub enclosing_block {
  my ($sr, $pos) = @_;
  for (my $k = $pos - 1; $k >= 0; $k--) {
    next unless substr($$sr, $k, 1) eq '{';
    my $e = match_close($sr, $k);
    return [$k, $e] if $e > $pos;
  }
  return [0, length $$sr];
}

# Definition of identifier $id visible at $use: the `id=<value>` whose
# enclosing block is the innermost one that also contains $use. Minified
# names are reused in every scope, so a module-wide first match is wrong.
# Returns the index just past `id=`, or undef if none or ambiguous.
sub resolve_def {
  my ($id, $sr, $use) = @_;
  my $saved = pos($$sr);    # never disturb a caller's //g loop over the same string
  my @defs;
  pos($$sr) = 0;
  while ($$sr =~ /(?<![\w\$.])\Q$id\E=(?![=>])/g) {
    # `for(let x=..;..)` is scoped to its loop, which the use is not inside
    # whenever the use comes first.
    next if substr($$sr, 0, $-[0]) =~ /for\((?:let|const) $/ && defined $use && $use < $-[0];
    push @defs, $+[0];
  }
  pos($$sr) = $saved;
  return undef unless @defs;
  return $defs[0] if @defs == 1 && !defined $use;
  return undef unless defined $use;
  my ($best, $bsize, $tie);
  for my $d (@defs) {
    my $b = enclosing_block($sr, $d);
    next unless $use > $b->[0] && $use < $b->[1];
    my $size = $b->[1] - $b->[0];
    if (!defined $best || $size < $bsize) { ($best, $bsize, $tie) = ($d, $size, 0) }
    elsif ($size == $bsize) { $tie = 1 }
  }
  return $tie ? undef : $best;
}

# Resolve the value of an expression to a Perl scalar (string), an array ref
# of strings, or undef when it is not a static literal. $use is where the
# expression appears in $$ctx, for scope-aware identifier lookup.
sub lit {
  my ($e, $ctx, $use) = @_;
  $ctx //= $SR;
  $e =~ s/^\s+|\s+$//g;
  $e =~ s/^\((.*)\)$/$1/s while $e =~ /^\(/ && match_close(\$e, 0) == length($e) - 1;
  return unquote($e) if $e =~ /^"(?:[^"\\]|\\.)*"$/s || $e =~ /^'(?:[^'\\]|\\.)*'$/s;
  return $1 if $e =~ /^`([^`\$\\]*)`$/;
  return 'true' if $e eq '!0' || $e eq 'true';
  return 'false' if $e eq '!1' || $e eq 'false';
  return $e if $e =~ /^-?\d+(?:\.\d+)?$/;
  if ($e =~ /^\[(.*)\]$/s) {
    my @v;
    for my $a (split_args($1)) {
      my $x = lit($a, $ctx);
      return undef unless defined $x && !ref $x;
      push @v, $x;
    }
    return \@v;
  }
  if ($e =~ /^[\w\$]+$/) {                         # local constant
    my $d = resolve_def($e, $ctx, $use);
    return undef unless defined $d;
    my $v = substr($$ctx, $d, 1) =~ /^["'\[]/ ? substr($$ctx, $d, 1) : '';
    return undef unless $v;
    my $c = $v eq '[' ? match_close($ctx, $d) : str_end($ctx, $d);
    return $c > $d ? lit(substr($$ctx, $d, $c - $d + 1), $ctx) : undef;
  }
  if ($e =~ /^([\w\$]+)\.([\w\$]+)$/ && $ctx == $SR && exists $IMPORT{$1}) {   # imported constant
    my ($m) = find_module($IMPORT{$1});
    return undef unless defined $m;
    my %x = module_exports($m);
    return undef unless exists $x{$2};
    my $use = index($m, "$2:()=>");
    return lit($x{$2}, \$m, $use < 0 ? undef : $use);
  }
  return undef;
}

# Render a value for the record stream: lists comma-joined, values with
# separators or spaces quoted, non-literals as `?`.
sub render {
  my $v = shift;
  return '?' unless defined $v;
  return join(',', map { render($_) } @$v) if ref $v;
  return '""' if $v eq '';
  if ($v =~ /[\s,|"=]/) { (my $q = $v) =~ s/(["\\])/\\$1/g; $q =~ s/\n/\\n/g; return "\"$q\"" }
  return $v;
}

# ---------------------------------------------------------------------------
# Guards: if-blocks and `X&&` prefixes that gate registrations
# ---------------------------------------------------------------------------

# Unique gate expressions, joined with `+` (all must pass).
sub merge_gates {
  my %seen;
  my @e = grep { !$seen{$_}++ } map { split /\+/ } map { s/^gated://r } @_;
  return 'gated:' . join('+', @e);
}

my $CHAIN_HEAD;    # start of the chain being walked, for `X&&` guards
my @IFS;    # [cond_start, cond_end, body_start, body_end, cond_text]
while ($S =~ /(?<![\w\$.])if\(/g) {
  my $o = $+[0] - 1;
  my $c = match_close($SR, $o);
  next if $c < 0;
  next unless substr($S, $c + 1, 1) eq '{';
  my $b = match_close($SR, $c + 1);
  next if $b < 0;
  # `if(a.command(..),b.command(..),cond){` evaluates to its last operand.
  my @ops = split_args(substr($S, $o + 1, $c - $o - 1));
  push @IFS, [$o, $c, $c + 1, $b, $ops[-1] // ''];
}

# Classify a guard expression: 'dev-only', 'gated:<expr>', 'noop', or
# 'other' (not a guard this miner understands).
sub classify_guard {
  my $cond = shift;
  for my $k ($cond =~ /(?<![\w\$.])\Q$CONST\E\.([\w\$]+)/g) {
    return 'dev-only' if $DEV_FALSE{$k};
  }
  my @gates;
  (my $x = $cond) =~ s/\(0,\Q$STATSIG\E\.[\w\$]+\)\("([^"]+)"\)|(?<![\w\$.])\Q$STATSIG\E\.[\w\$]+\("([^"]+)"\)/push @gates, ($1 \/\/ $2); $gates[-1]/ge;
  if (@gates) {
    return "gated:$x" if $x =~ /^[\w!&|()]+$/;
    return 'gated:' . join(',', @gates);
  }
  for my $k ($cond =~ /(?<![\w\$.])\Q$CONST\E\.([\w\$]+)/g) {
    return 'noop' if $DEV_TRUE{$k} && $cond =~ /^\s*\Q$CONST\E\.\Q$k\E\s*$/;
  }
  return 'other';
}

# Left operand of a `X&&` immediately before $pos, or undef.
sub and_prefix {
  my $pos = shift;
  my $k = $pos - 1;
  return undef unless $k >= 1 && substr($S, $k - 1, 2) eq '&&';
  $k -= 2;
  my $end = $k;
  my $depth = 0;
  for (; $k >= 0; $k--) {
    my $c = substr($S, $k, 1);
    if ($c eq ')' || $c eq ']') { $depth++; next }
    if ($c eq '(' || $c eq '[') { last if $depth == 0; $depth--; next }
    last if $depth == 0 && $c =~ /[,;{}?:=]/;
  }
  return substr($S, $k + 1, $end - $k);
}

# Guard class in effect at $pos: 'dev-only', 'gated:...', 'cond' (a runtime
# condition that is neither), or undef. A `X&&` prefix is looked for before
# $head, the start of the chain the registration belongs to.
sub guard_at {
  my ($pos, $head) = @_;
  my @cls;
  for my $f (@IFS) {
    next unless $pos > $f->[2] && $pos < $f->[3];
    push @cls, classify_guard($f->[4]);
  }
  my $p = and_prefix($head // $pos);
  push @cls, classify_guard($p) if defined $p;
  return 'dev-only' if grep { $_ eq 'dev-only' } @cls;
  my @g = grep { /^gated:/ } @cls;
  return merge_gates(@g) if @g;
  return 'cond' if grep { $_ eq 'other' } @cls;
  return undef;
}

# ---------------------------------------------------------------------------
# Named function declarations (for helper and template detection)
# ---------------------------------------------------------------------------

my @FUNCS;    # [name, [params], body_start, body_end, decl_start]
while ($S =~ /(?<![\w\$.])function\s*([\w\$]+)\(([\w\$,]*)\)\{/g) {
  my ($name, $params, $ds, $bs) = ($1, $2, $-[0], $+[0] - 1);
  my $be = match_close($SR, $bs);
  next if $be < 0;
  push @FUNCS, [$name, [split /,/, $params], $bs, $be, $ds];
}

sub enclosing_func {
  my $pos = shift;
  my $best;
  for my $f (@FUNCS) {
    next unless $pos > $f->[2] && $pos < $f->[3];
    $best = $f if !$best || $f->[2] > $best->[2];
  }
  return $best;
}

# Call sites of a named function: list of [pos, [args], argument-list start].
sub call_sites {
  my $f = shift;
  my @out;
  my $name = $f->[0];
  while ($S =~ /(?<![\w\$.])\Q$name\E\(/g) {
    my $p = $-[0];
    next if $p == $f->[4] + index(substr($S, $f->[4], 40), $name);   # the declaration
    my $o = $+[0] - 1;
    my $c = match_close($SR, $o);
    next if $c < 0;
    push @out, [$p, [split_args(substr($S, $o + 1, $c - $o - 1))], $o + 1];
    pos($S) = $o + 1;
  }
  return @out;
}

# ---------------------------------------------------------------------------
# Command tree
# ---------------------------------------------------------------------------

my @NODES;    # {path, name, parent, hidden, gate, aliases, args, action, ...}
my %BYPATH;

sub new_node {
  my ($parent, $name, %a) = @_;
  my $path = defined $parent ? "$NODES[$parent]{path} $name" : $name;
  my $id = scalar @NODES;
  push @NODES, { path => $path, name => $name, parent => $parent, aliases => [], args => [],
                 opts => [], hidden => 0, %a };
  push @{ $BYPATH{$path} }, $id;
  return $id;
}

my $ROOT = new_node(undef, 'agent');

# Positions of the registration calls attributed to a command, for the
# self-check below.
my %CONSUMED;

# Parse a commander option spec into (flags, value kind, variadic).
sub spec_info {
  my $spec = shift;
  my @flags = grep { /^-/ } split /[ ,|]+/, $spec;
  my $value = $spec =~ /<[^>]*>/ ? 'required' : $spec =~ /\[[^\]]*\]/ ? 'optional' : 'none';
  my $variadic = $spec =~ /\.\.\.[>\]]/ ? 1 : 0;
  return (\@flags, $value, $variadic);
}

# Parser function heuristics: `(t,e=[])=>[...e,t]` style accumulators.
sub parser_kind {
  my $e = shift;
  return $e =~ /\[\.\.\.[\w\$]+/ ? 'repeatable' : 'custom';
}

sub add_opt {
  my ($nodes, $pos, %o) = @_;
  my $g = guard_at($pos, $CHAIN_HEAD);
  for my $n (@$nodes) {
    push @{ $NODES[$n]{opts} }, { %o, gate => $g };
  }
}

# Process `new X("spec","desc").m(...)...` (the argument of .addOption).
sub option_object {
  my ($nodes, $expr, $pos) = @_;
  $expr =~ s/^\s+//;
  return 0 unless $expr =~ /^new\s+[\w\$]+(?:\.[\w\$]+)?\(/;
  my $o = $+[0] - 1;
  my $c = match_close(\$expr, $o);
  my @ca = split_args(substr($expr, $o + 1, $c - $o - 1));
  my $spec = lit($ca[0], $SR, $pos);
  return 0 unless defined $spec && !ref $spec;
  my %o = (spec => $spec);
  my $j = $c + 1;
  while (substr($expr, $j) =~ /^\.([\w\$]+)\(/) {
    my $m = $1;
    my $mo = $j + length($m) + 1;
    my $mc = match_close(\$expr, $mo);
    my $arg = substr($expr, $mo + 1, $mc - $mo - 1);
    if ($m eq 'hideHelp') {
      my $v = $arg eq '' ? 'true' : lit($arg, $SR, $pos);
      $o{hidden} = !defined $v ? 'cond' : $v eq 'true' ? 1 : 0;
    }
    elsif ($m eq 'choices')   { $o{choices} = render(lit($arg, $SR, $pos)) }
    elsif ($m eq 'default')   { my @a = split_args($arg); $o{default} = render(lit($a[0], $SR, $pos)) }
    elsif ($m eq 'preset')    { $o{preset} = render(lit($arg, $SR, $pos)) }
    elsif ($m eq 'env')       { $o{env} = render(lit($arg, $SR, $pos)) }
    elsif ($m eq 'conflicts') { my $v = lit($arg, $SR, $pos); $o{conflicts} = ref $v ? $v : [$v // '?'] }
    elsif ($m eq 'implies')   { $o{implies} = 1 }
    elsif ($m eq 'argParser') { $o{parser} = parser_kind($arg) }
    elsif ($m eq 'makeOptionMandatory') { $o{mandatory} = 1 }
    $j = $mc + 1;
  }
  add_opt($nodes, $pos, %o);
  return 1;
}

my %HELPER_OPTS;   # function name -> list of option hashes applied to its param
my @CHAINS;        # [start, end, [final nodes]]

# Expand a `.command(<ident>,...)` inside a named function into one node per
# call site, using the literal at the parameter's position.
sub template_names {
  my ($ident, $pos) = @_;
  my $f = enclosing_func($pos) or return;
  my ($idx) = grep { $f->[1][$_] eq $ident } 0 .. $#{ $f->[1] };
  return unless defined $idx;
  my @out;
  for my $cs (call_sites($f)) {
    my $v = lit($cs->[1][$idx] // '', $SR, $cs->[0]);
    push @out, [$v, $cs->[0], $cs->[0]] if defined $v && !ref $v;
  }
  return @out;
}

# Walk the method chain whose first `.` is at $j, applying registrations to
# @$nodes. Returns (end position, final nodes).
sub walk_chain {
  my ($j, $nodes) = @_;
  my $n = length $S;
  while (1) {
    if (substr($S, $j, 1) eq ')') {
      # `(X=a.command(..),X.option(..)).argument(..)` and `helper(a.command(..)).action(..)`:
      # the chain continues on the wrapped value.
      my $k = $j;
      $k++ while substr($S, $k, 1) eq ')';
      last unless substr($S, $k) =~ /^\.(?:option|requiredOption|addOption|argument|arguments|alias|aliases|action|description|allowExcessArguments)\(/;
      $j = $k;
    }
    last unless substr($S, $j, 300) =~ /^\.([\w\$]+)\(/;
    my $m = $1;
    my $o = $j + length($m) + 1;
    my $c = match_close($SR, $o);
    last if $c < 0;
    my $arg = substr($S, $o + 1, $c - $o - 1);
    if ($m eq 'command') {
      $CONSUMED{$j} = 1;
      my @a = split_args($arg);
      my (@names);
      my $f = $a[0] =~ /^[\w\$]+$/ ? enclosing_func($j) : undef;
      if ($f && grep { $_ eq $a[0] } @{ $f->[1] }) {
        @names = template_names($a[0], $j);
        need("cannot resolve command name `$a[0]` at offset $j") unless @names;
      } elsif (defined(my $v = lit($a[0], $SR, $j))) {
        @names = ([$v, $j, $CHAIN_HEAD]);
      } else {
        need("unrecognized .command() argument at offset $j");
      }
      my ($hidden, $isdef) = (0, 0);
      if (defined $a[1] && $a[1] =~ /^\{(.*)\}$/s) {
        my $obj = $1;
        if ($obj =~ /(?:^|,)hidden:([^,}]+)/) {
          my $v = lit($1, $SR, $j);
          $hidden = !defined $v ? 'cond' : $v eq 'true' ? 1 : 0;
        }
        $isdef = 1 if $obj =~ /(?:^|,)isDefault:!0/;
      }
      my @new;
      for my $p (@$nodes) {
        for my $nm (@names) {
          my ($name, @args) = split ' ', $nm->[0];
          my $id = new_node($p, $name, hidden => $hidden, isdefault => $isdef,
                            gate => guard_at($nm->[1], $nm->[2]));
          push @{ $NODES[$id]{args} }, @args;
          push @new, $id;
        }
      }
      $nodes = \@new;
    }
    elsif ($m eq 'option' || $m eq 'requiredOption') {
      $CONSUMED{$j} = 1;
      my @a = split_args($arg);
      my $spec = lit($a[0], $SR, $j);
      need("non-literal option spec at offset $j") unless defined $spec && !ref $spec;
      my %o = (spec => $spec);
      $o{mandatory} = 1 if $m eq 'requiredOption';
      if (defined $a[2]) {
        if ($a[2] =~ /=>|^\(?function/) {
          $o{parser} = parser_kind($a[2]);
          $o{default} = render(lit($a[3], $SR, $j)) if defined $a[3];
        } else {
          $o{default} = render(lit($a[2], $SR, $j));
        }
      }
      add_opt($nodes, $j, %o);
    }
    elsif ($m eq 'addOption') {
      $CONSUMED{$j} = 1;
      option_object($nodes, $arg, $j) or need("unrecognized .addOption() argument at offset $j");
    }
    elsif ($m eq 'argument' || $m eq 'arguments') {
      $CONSUMED{$j} = 1;
      my @a = split_args($arg);
      my $v = lit($a[0], $SR, $j);
      need("non-literal argument spec at offset $j") unless defined $v && !ref $v;
      push @{ $NODES[$_]{args} }, split(' ', $v) for @$nodes;
    }
    elsif ($m eq 'alias' || $m eq 'aliases') {
      $CONSUMED{$j} = 1;
      my $v = lit($arg, $SR, $j);
      push @{ $NODES[$_]{aliases} }, (ref $v ? @$v : ($v // '?')) for @$nodes;
    }
    elsif ($m eq 'action')        { $NODES[$_]{action} = 1 for @$nodes }
    elsif ($m eq 'helpOption')    { $NODES[$_]{helpopt} = lit((split_args($arg))[0] // '', $SR, $j) for @$nodes }
    elsif ($m eq 'helpCommand')   { $NODES[$_]{helpcmd} = lit((split_args($arg))[0] // '', $SR, $j) for @$nodes }
    elsif ($m =~ /^(allowExcessArguments|allowUnknownOption|passThroughOptions|enablePositionalOptions)$/) {
      my $v = $arg eq '' ? 'true' : lit($arg, $SR, $j);
      $NODES[$_]{settings}{$m} = $v // '?' for @$nodes;
    }
    $j = $c + 1;
  }
  return ($j, $nodes);
}

# --- root: `X=(new C.K)` or `X=new C.K(` with C the commander import -------
$S =~ /(?<![\w\$.])([\w\$]+)=\(?new \Q$CMDR\E\.[\w\$]+(?:\(\))?\)?(?=\.)/
  or need("root program (new <commander>.Command) not found in ./src/cli.ts");
my %VARS = ($1 => [$ROOT]);
my %VAR_AT = ($1 => $-[0]);    # where each variable was last bound
my ($ROOT_END) = walk_chain($+[0], [$ROOT]);

# --- every other chain, in source order -----------------------------------
my $REGM = qr/command|option|requiredOption|addOption|argument|arguments|alias|aliases|description|action|addHelpText|helpOption|helpCommand|allowExcessArguments|allowUnknownOption|passThroughOptions|enablePositionalOptions/;
my $done_to = $ROOT_END;
while ($S =~ /(?<![\w\$.])([\w\$]+)(?=\.(?:$REGM)\()/g) {
  my ($recv, $hs, $he) = ($1, $-[0], $+[0]);
  next if $hs < $done_to;
  my ($nodes, $helper);
  my $f = enclosing_func($hs);
  if ($f && (grep { $_ eq $recv } @{ $f->[1] }) && !($VARS{$recv} && $VAR_AT{$recv} > $f->[2])) {
    # A helper that registers options on its parameter, e.g. `function k(t){return t.addOption(..)}`.
    $helper = $f->[0];
    $nodes = [new_node(undef, "<helper $helper>")];
  } elsif ($VARS{$recv}) {
    $nodes = $VARS{$recv};
  } else {
    next;
  }
  $CHAIN_HEAD = $hs;
  my ($end, $final) = walk_chain($he, $nodes);
  $done_to = $end;
  pos($S) = $end;
  push @CHAINS, [$hs, $end, $final];
  if (defined $helper) {
    push @{ $HELPER_OPTS{$helper} }, @{ $NODES[$nodes->[0]]{opts} };
    next;
  }
  # `X=<chain>` binds X to the chain's final command(s).
  my $before = substr($S, $hs > 80 ? $hs - 80 : 0, $hs > 80 ? 80 : $hs);
  if ($before =~ /(?<![\w\$.=!<>])([\w\$]+)=$/) {
    my $var = $1;
    if (substr($S, $hs, $end - $hs) =~ /\.(?:$REGM)\(/) { $VARS{$var} = $final; $VAR_AT{$var} = $hs }
  }
}

# --- helper call sites: `helper(<chain>)` applies the helper's options -----
for my $f (@FUNCS) {
  next unless $HELPER_OPTS{ $f->[0] };
  for my $cs (call_sites($f)) {
    my $astart = $cs->[2];
    $astart++ while substr($S, $astart, 1) =~ /\s/;
    my ($ch) = grep { $_->[0] == $astart } @CHAINS;
    need("helper $f->[0]() called on something other than a command chain at offset $cs->[0]") unless $ch;
    for my $n (@{ $ch->[2] }) {
      push @{ $NODES[$n]{opts} }, map { { %$_, gate => guard_at($cs->[0]) } } @{ $HELPER_OPTS{ $f->[0] } };
    }
  }
}

# --- self-check: every registration call was attributed to a command -------
{
  my @missed;
  while ($S =~ /\.(command|option|requiredOption|addOption|argument|arguments|alias|aliases)\(/g) {
    my $p = $-[0];
    next if $CONSUMED{$p};
    my $snip = substr($S, $p, 60);
    $snip =~ s/[^ -~]/?/g;
    push @missed, "offset $p: $snip";
  }
  need("registration calls not attributed to any command:\n  " . join("\n  ", @missed)) if @missed;
}

# ---------------------------------------------------------------------------
# Tiers
# ---------------------------------------------------------------------------

sub combine_tier {
  my ($own_gate, $own_hidden, $parent) = @_;
  return 'dev-only' if ($own_gate // '') eq 'dev-only' || ($parent // '') eq 'dev-only';
  my @g = grep { defined && /^gated:/ } ($parent, $own_gate);
  return merge_gates(@g) if @g;
  return 'hidden' if $own_hidden || ($parent // '') eq 'hidden';
  return 'visible';
}

sub node_tier {
  my $id = shift;
  my $nd = $NODES[$id];
  return $nd->{tier} if exists $nd->{tier};
  my $pt = defined $nd->{parent} ? node_tier($nd->{parent}) : undef;
  return $nd->{tier} = combine_tier($nd->{gate}, $nd->{hidden}, $pt);
}

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

my @OUT;
sub rec { push @OUT, join(' | ', @_) }

sub hidden_attr {
  my $h = shift;
  return $h eq 'cond' ? ('hidden=cond') : $h ? ('hidden') : ();
}

# commander attribute name of a long flag: --all-pools -> allPools, --no-x -> x
sub attr_name {
  my $f = shift;
  $f =~ s/^--(?:no-)?//;
  $f =~ s/-(.)/\U$1/g;
  return $f;
}

my %PRESCAN;    # filled below, before emission of options

sub emit_tree {
  for my $id (0 .. $#NODES) {
    my $nd = $NODES[$id];
    next if $nd->{name} =~ /^<helper /;
    my $tier = node_tier($id);
    my $kids = grep { defined $_->{parent} && $_->{parent} == $id } @NODES;
    if (defined $nd->{parent}) {
      my @a = hidden_attr($nd->{hidden});
      push @a, 'default-command' if $nd->{isdefault};
      push @a, 'conditional' if ($nd->{gate} // '') eq 'cond';
      push @a, 'aliases=' . join(',', @{ $nd->{aliases} }) if @{ $nd->{aliases} };
      push @a, 'subcommands' if $kids;
      push @a, 'action' if $nd->{action};
      push @a, map { "$_=$nd->{settings}{$_}" } sort keys %{ $nd->{settings} // {} };
      rec('cmd', $NODES[$nd->{parent}]{path}, $nd->{name}, $tier, @a);
    }
    my $pos = 0;
    for my $a (@{ $nd->{args} }) {
      $pos++;
      my $kind = $a =~ /^</ ? 'required' : 'optional';
      $kind .= ' variadic' if $a =~ /\.\.\.[>\]]$/;
      rec('arg', $nd->{path}, $a, $tier, "pos=$pos", $kind);
    }
    # Commander's implicit help command: explicit .helpCommand(), or
    # subcommands and no action handler.
    my $hc = $nd->{helpcmd};
    if ((defined $hc && $hc ne 'false') || (!defined $hc && $kids && !$nd->{action})) {
      my ($hname, @hargs) = split ' ', (defined $hc && $hc ne 'true' ? $hc : 'help [command]');
      rec('cmd', $nd->{path}, $hname, $tier, 'builtin', ($kids ? 'subcommands' : ()), 'action');
      my $p = 0;
      rec('arg', "$nd->{path} $hname", $_, $tier, 'pos=' . ++$p, 'optional') for @hargs;
    }
    my $hspec = $nd->{helpopt} // '-h, --help';
    rec('opt', $nd->{path}, $hspec, $tier, 'value=none', 'builtin') unless $hspec eq 'false';
    my %attr_to_flag;
    for my $o (@{ $nd->{opts} }) {
      my ($fl) = spec_info($o->{spec});
      my ($long) = grep { /^--/ } @$fl;
      $attr_to_flag{ attr_name($long) } = $long if $long;
    }
    for my $o (@{ $nd->{opts} }) {
      my ($fl, $value, $variadic) = spec_info($o->{spec});
      my @a = hidden_attr($o->{hidden} // 0);
      push @a, "value=$value";
      push @a, 'variadic' if $variadic;
      push @a, 'mandatory' if $o->{mandatory};
      push @a, 'repeatable' if ($o->{parser} // '') eq 'repeatable';
      push @a, 'parser' if ($o->{parser} // '') eq 'custom';
      push @a, "choices=$o->{choices}" if defined $o->{choices};
      push @a, "default=$o->{default}" if defined $o->{default};
      push @a, "preset=$o->{preset}" if defined $o->{preset};
      push @a, "env=$o->{env}" if defined $o->{env};
      push @a, 'conflicts=' . join(',', map { $attr_to_flag{$_} // $_ } @{ $o->{conflicts} }) if $o->{conflicts};
      push @a, 'implies' if $o->{implies};
      push @a, 'conditional' if ($o->{gate} // '') eq 'cond';
      push @a, 'prescan' if $id == $ROOT && grep { $PRESCAN{$_} } @$fl;
      rec('opt', $nd->{path}, $o->{spec}, combine_tier($o->{gate}, $o->{hidden}, $tier), @a);
    }
  }
}

sub tier_of_path {
  my $p = shift;
  my ($id) = @{ $BYPATH{$p} // [] };
  return defined $id ? node_tier($id) : 'unregistered';
}

# Tier of the option on $path that declares flag $flag.
sub opt_tier {
  my ($p, $flag) = @_;
  for (@OUT) {
    my @f = split / \| /;
    next unless $f[0] eq 'opt' && $f[1] eq $p;
    my ($fl) = spec_info($f[2]);
    return $f[3] if grep { $_ eq $flag } @$fl;
  }
  return 'unregistered';
}

# --- raw-argv pre-scans: flags read from process.argv before commander ------
# The flags compared inside the innermost named function or arrow body that
# reads process.argv.
while ($S =~ /process\.argv/g) {
  my $p = $-[0];
  my ($bs, $be);
  for (my $k = $p; $k >= 0 && $k > $p - 4000; $k--) {
    next unless substr($S, $k, 1) eq '{';
    next unless substr($S, 0, $k) =~ /(?:\)|=>)$/;
    my $e = match_close($SR, $k);
    next unless $e > $p;
    ($bs, $be) = ($k, $e);
    last;
  }
  next unless defined $bs;
  my $body = substr($S, $bs, $be - $bs);
  next if length $body > 4000;          # an action handler, not a pre-scan
  $PRESCAN{$_} = 1 for $body =~ /"(--[\w-]+)"===/g, $body =~ /==="(--[\w-]+)"/g,
                       $body =~ /startsWith\("(--[\w-]+)=?"\)/g;
}
# ... and flags handed to an argv-scanning helper: `f(x.argv,"--flag")`.
$PRESCAN{$_} = 1 for $S =~ /[\w\$]\((?:[\w\$]+\.)*argv,"(--[\w-]+)"\)/g;
# Help-flag sniffing (e.g. to pick which help to print) is not a pre-scan.
my ($HELP_FLAGS) = spec_info($NODES[$ROOT]{helpopt} // '-h, --help');
delete @PRESCAN{@$HELP_FLAGS};

# --- the root's own flags, to tag prescans that have a registration --------
my %ROOT_FLAGS;
for my $o (@{ $NODES[$ROOT]{opts} }) { my ($fl) = spec_info($o->{spec}); $ROOT_FLAGS{$_} = 1 for @$fl }

emit_tree();
rec('prescan', 'agent', $_, 'static', 'unregistered') for grep { !$ROOT_FLAGS{$_} } sort keys %PRESCAN;

# --- persist: hand-rolled grammar dispatched before commander --------------
{
  my ($m, $file) = find_module('./src/persistence/persistent-session.ts');
  need("module ./src/persistence/persistent-session.ts not found") unless defined $m;
  my $t = tier_of_path('agent persist');
  my $n = 0;
  while ($m =~ /"((?:[^"\\]|\\.)*)"/g) {
    my $s = unquote("\"$1\"");
    next unless $s =~ /^Usage:\n/;
    for my $l (split /\n/, $s) {
      next unless $l =~ /^\s+(agent persist\b.*?)\s*$/;
      rec('grammar', 'agent persist', 'usage', $t, $1);
      $n++;
    }
  }
  need("persist help text (Usage: ... agent persist ...) not found in $file") unless $n;
  my $i = index($m, '"persist"===');
  need("persist argv dispatcher not found in $file") if $i < 0;
  # The words compared inside the `if("persist"===argv[0]){...}` block.
  my $b = index($m, '{', $i);
  my $e = match_close(\$m, $b);
  need("persist argv dispatcher block not delimited in $file") if $e < 0;
  my $blk = substr($m, $b, $e - $b);
  my %seen;
  for my $w ($blk =~ /"([\w-]+)"===[\w\$]+(?!\[)/g) {
    next if $seen{$w}++;
    rec('grammar', 'agent persist', ($w =~ /^-/ ? 'help-flag' : 'subcommand'), $t, $w);
  }
  rec('grammar', 'agent persist', 'restore-marker', 'dev-only', $1)
    if $m =~ /(?<![\w\$.])[\w\$]+="(--[\w-]*persist[\w-]*)"/;
}

# --- worker --pool argv rewrite ---------------------------------------------
{
  my ($m, $file) = find_module('./src/commands/worker-pool.ts');
  need("module ./src/commands/worker-pool.ts not found") unless defined $m;
  my $t = tier_of_path('agent worker');
  # A bare `--pool` is rewritten to `--pool=<constant>`; `--pool <word>`
  # becomes `--pool=<word>` (a template on a loop variable, skipped here).
  my $bare;
  while (!defined $bare && $m =~ /`--pool=\$\{([\w\$]+)\}`/g) { $bare = lit($1, \$m, $-[0]) }
  need("--pool rewrite default (`--pool=\${<constant>}`) not found in $file") unless defined $bare && !ref $bare;
  rec('grammar', 'agent worker', 'pool-bare-value', $t, render($bare));
  # Words that end a `--pool` with no value (the worker subcommands).
  my $stop = $m =~ /new Set\(([\w\$]+)\)/ ? lit($1, \$m, $-[0]) : undef;
  need("--pool rewrite stop-word set not found in $file") unless ref $stop;
  rec('grammar', 'agent worker', 'pool-stop-words', $t, render($stop));
  my %f;
  $f{$_} = 1 for $m =~ /"(--[\w-]+=?)"[!=]==/g, $m =~ /[!=]=="(--[\w-]+=?)"/g, $m =~ /startsWith\("(--[\w-]+=?)"\)/g;
  rec('grammar', 'agent worker', 'pool-rewrite-flags', $t, join(',', sort keys %f));
}

# --- validators and enums outside cli.ts ------------------------------------
{
  my ($m, $file) = find_module('./src/utils/output-format.ts');
  need("module ./src/utils/output-format.ts not found") unless defined $m;
  $m =~ /(?<![\w\$.])[\w\$]+=(\[(?:"[^"]*",?)+\])/ or need("--output-format value list not found in $file");
  rec('enum', 'agent', '--output-format', opt_tier('agent', '--output-format'),
      'values=' . render(lit($1, \$m, $-[0])), 'source=validator');
}
{
  my ($m, $file) = find_module('../cursor-config/dist/schema.js');
  need("module ../cursor-config/dist/schema.js (channel schema) not found") unless defined $m;
  $m =~ /(?<![\w\$])channel:/ or need("channel field not found in $file");
  my $rest = substr($m, $+[0], 400);
  my ($expr) = split_args($rest);
  my @v = $expr =~ /\("([^"]+)"\)/g;
  need("channel values not found in $file") unless @v;
  rec('enum', 'agent set-channel', '<channel>', tier_of_path('agent set-channel'),
      'values=' . render([sort @v]), 'source=config-schema');
}
{
  my ($m, $file) = find_module('./src/commands/shell-integration.ts');
  need("module ./src/commands/shell-integration.ts not found") unless defined $m;
  my $i = index($m, 'Unsupported shell');
  need("shell validator (Unsupported shell) not found in $file") if $i < 0;
  my $w = substr($m, $i > 300 ? $i - 300 : 0, $i > 300 ? 300 : $i);
  $w =~ s/.*\bif\(//s;
  my @v = $w =~ /"([\w-]+)"[!=]==/g;
  need("shell values not found in $file") unless @v;
  rec('enum', 'agent shell-integration', '<shell>', tier_of_path('agent shell-integration'),
      'values=' . render([sort @v]), 'source=validator');
}

# --- anchors -----------------------------------------------------------------
{
  my %have;
  for (@OUT) {
    my @f = split / \| /;
    $have{"$f[0] $f[1] $f[2]"} = 1;
    if ($f[0] eq 'opt') { my ($fl) = spec_info($f[2]); $have{"flag $f[1] $_"} = 1 for @$fl }
  }
  for my $a ('flag agent --print', 'cmd agent mcp', 'cmd agent worker') {
    need("anchor entry missing: $a") unless $have{$a};
  }
}

my $VERSION = $VDIR =~ s{/+$}{}r =~ s{.*/}{}r;
rec('meta', 'agent', 'version', 'static', $VERSION);
rec('meta', 'agent', 'module', 'static', "./src/cli.ts in $CLI_FILE");
pos($S) = undef;
if (my @bv = $S =~ /"(\d{4}\.\d\d\.\d\d-[0-9a-f]{6,})"/g) {
  my %u = map { $_ => 1 } @bv;
  rec('meta', 'agent', 'bundle-version', 'static', join(',', sort keys %u));
  print STDERR "check-drift: warning: version directory $VERSION does not match the version compiled into the bundle\n"
    unless $u{$VERSION};
}
print "$_\n" for @OUT;
PERL
}

# Writes the mined records, sorted, to stdout. Exits 2 if the miner needs
# attention. Must run in the current shell (not in `$(...)` or a pipeline),
# or the exit only leaves a subshell.
mine_static() {
  local dir=$1 minepl out rc
  command -v perl >/dev/null 2>&1 || die "perl not found; the miner needs it"
  new_tmpfile; minepl=$REPLY
  new_tmpfile; out=$REPLY
  write_miner >|"$minepl"
  perl -- "$minepl" "$dir" >|"$out"
  rc=$?
  (( rc == 2 )) && exit 2                 # the miner already said why
  (( rc == 0 )) || die "miner failed on $dir (perl exit $rc)"
  sort -- "$out"
}

# ---------------------------------------------------------------------------
# Execution half: running the CLI
# ---------------------------------------------------------------------------
#
# The rules below come from a safety analysis of this CLI (the hazards in
# CLAUDE.md are the short form):
#   - Only two argv shapes are ever run: `<words> --help` on a registered
#     command path, and the option probe `<words> <flag> --zz-bogus-1
#     --zz-bogus-2`. A required value eats --zz-bogus-1 and the root parser
#     shadowing a leaf option eats at most one more token, so --zz-bogus-2 is
#     always left over as an unknown option and the line cannot parse cleanly.
#     Shorter probes can: `agent --resume` resumes a chat, and `agent worker
#     start --data-dir --zz-bogus` starts a worker (the root's own hidden
#     --data-dir takes the bogus flag as its value).
#   - `persist` is dispatched on raw argv before commander. Only exactly
#     `persist --help` is safe; `persist attach --help` runs tmux with
#     `--help` as the session name.
#   - Gated and dev-only commands are not registered in isolation, so any
#     line naming them is a root prompt line. They are never run.
#   - Never `--help` after an option (a required option would take it as its
#     value), and never a positional word (a prompt starts a session).

typeset -gi RUN_RC=0 RUN_COUNT=0 RUN_CAP=20 GUARD_READY=0
typeset -g RUN_OUT='' RUN_ERR='' RUNNER_PL=''
# Guard tables, filled from the mined records by guard_init.
typeset -gA GUARD_PATHS GUARD_DENY GUARD_NOPROBE

# The runner: forks the CLI in its own process group with an environment built
# from scratch, waits up to <cap> seconds, then TERM to the group, 3 s grace,
# KILL. It also kills the group if it is interrupted or its parent goes away,
# and reaps anything the CLI left running. Writes `<exit> <signal> <killed>
# <leftover>` to <dir>/status; exits 130 if it was interrupted.
write_runner() {
  cat <<'PERL'
use strict;
use warnings;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

my ($d, $cap, $exe, @argv) = @ARGV;
# AGENT_CLI_CREDENTIAL_STORE=memory keeps the CLI away from the login
# keychain; TMPDIR keeps its debug logs out of the shared /tmp log dir.
my %env = (
  PATH => '/usr/bin:/bin:/usr/sbin:/sbin',
  HOME => "$d/home",
  CURSOR_CONFIG_DIR => "$d/home/.cursor",
  TMPDIR => "$d/tmp",
  TERM => 'dumb',
  LANG => 'en_US.UTF-8',
  AGENT_CLI_CREDENTIAL_STORE => 'memory',
);
my $parent = getppid();
my $stop = '';
$SIG{$_} = sub { $stop ||= shift } for qw(INT TERM HUP);
my $pid = fork;
defined $pid or die "fork: $!\n";
if (!$pid) {
  $SIG{$_} = 'DEFAULT' for qw(INT TERM HUP);
  setpgrp(0, 0);
  chdir "$d/cwd" or POSIX::_exit(126);
  open STDIN, '<', '/dev/null';
  open STDOUT, '>', "$d/out";
  open STDERR, '>', "$d/err";
  exec { '/usr/bin/env' } '/usr/bin/env', '-i', (map { "$_=$env{$_}" } sort keys %env), $exe, @argv
    or POSIX::_exit(127);
}
eval { setpgrp($pid, $pid) };    # also here, so no kill can race the child's own call
my ($st, $killed, $deadline) = (0, '', time + $cap);
while (1) {
  if (waitpid($pid, WNOHANG) == $pid) { $st = $?; last }
  $deadline = 0 if ($stop || getppid() != $parent) && !$killed;
  if (time > $deadline) {
    if (!$killed) { kill 'TERM', -$pid; $killed = 'TERM'; $deadline = time + 3 }
    elsif ($killed eq 'TERM') { kill 'KILL', -$pid; $killed = 'KILL' }
  }
  sleep 0.05;
}
my $left = kill(0, -$pid) ? 1 : 0;
if ($left) { kill 'TERM', -$pid; sleep 1; kill 'KILL', -$pid }
open my $fh, '>', "$d/status" or die "status: $!\n";
printf $fh "%d %d %s %d\n", $st >> 8, $st & 127, $killed || 'none', $left;
close $fh;
exit($stop ? 130 : 0);
PERL
}

# guard_argv <args...>
# The safety net under every execution, deliberately independent of the walk
# and probe logic: succeeds only for
#   persist --help                              exactly these two words
#   <words> --help                              the help walk
#   <words> <flag> --zz-bogus-1 --zz-bogus-2    the option probe
# where <words> are bare command words naming a registered command path that
# is neither gated nor dev-only, and <flag> is a bare flag that is not a help,
# version or `worker --pool` flag, on a path that does not accept unknown
# options. On refusal, sets REPLY to the reason.
guard_argv() {
  local -a w=("$@") words=()
  local opt='' word cmdpath prefix
  REPLY=''
  (( GUARD_READY )) || { REPLY="no mined command paths loaded"; return 1 }
  (( $#w )) || { REPLY="empty argv"; return 1 }
  if [[ $w[1] == persist ]]; then
    (( $#w == 2 )) && [[ $w[2] == --help ]] && return 0
    REPLY="under persist only 'persist --help' may run"
    return 1
  fi
  if [[ $w[-1] == --help ]]; then
    words=("${(@)w[1,-2]}")
  elif (( $#w >= 3 )) && [[ $w[-2] == --zz-bogus-1 && $w[-1] == --zz-bogus-2 ]]; then
    opt=$w[-3]
    words=("${(@)w[1,-4]}")
    [[ $opt == (-[A-Za-z]|--[A-Za-z][A-Za-z0-9-]#) ]] || { REPLY="'$opt' is not a bare flag"; return 1 }
    [[ $opt == (-h|--help|-v|--version|--zz-bogus-*|--cursor-persist-restore) ]] &&
      { REPLY="'$opt' is never probed"; return 1 }
    if [[ $opt == --pool* ]] && (( ${words[(Ie)worker]} )); then
      REPLY="'$opt' under worker is rewritten before commander"
      return 1
    fi
  else
    REPLY="neither '<command> --help' nor '<command> <flag> --zz-bogus-1 --zz-bogus-2'"
    return 1
  fi
  for word in $words; do
    [[ $word == [a-z][a-z0-9-]# ]] || { REPLY="'$word' is not a command word"; return 1 }
  done
  cmdpath=agent${words:+ ${(j: :)words}}
  prefix=agent
  for word in $words; do
    prefix+=" $word"
    [[ -n ${GUARD_DENY[$prefix]-} ]] && { REPLY="'$prefix' is ${GUARD_DENY[$prefix]}"; return 1 }
  done
  [[ -n ${GUARD_PATHS[$cmdpath]-} ]] || { REPLY="'$cmdpath' is not a registered command path"; return 1 }
  if [[ -n $opt && -n ${GUARD_NOPROBE[$cmdpath]-} ]]; then
    REPLY="options of '$cmdpath' are never probed (${GUARD_NOPROBE[$cmdpath]})"
    return 1
  fi
  return 0
}

# Registered paths and the never-run ones, from the mined records.
guard_init() {
  local line p
  local -a F
  GUARD_PATHS=(agent registered)
  GUARD_DENY=('agent persist' 'dispatched before commander')
  GUARD_NOPROBE=()
  for line in $MINED_LINES; do
    F=("${(@s: | :)line}")
    [[ $F[1] == cmd ]] || continue
    p="$F[2] $F[3]"
    case $F[4] in
      gated:*)  GUARD_DENY[$p]="gated ($F[4])" ;;
      dev-only) GUARD_DENY[$p]="dev-only" ;;
      *)        (( ${F[(Ie)builtin]} )) || GUARD_PATHS[$p]=registered ;;
    esac
    (( ${F[(Ie)allowUnknownOption=true]} )) && GUARD_NOPROBE[$p]="allowUnknownOption: the action would run"
  done
  GUARD_READY=1
}

# run_isolated <args...>
# The only place the CLI is ever executed: `<version-dir>/cursor-agent
# <args...>` after guard_argv, in a fresh throwaway directory (HOME,
# CURSOR_CONFIG_DIR, TMPDIR, and the cwd, which is outside any git repo),
# stdin </dev/null, capped at RUN_CAP seconds. Sets RUN_RC, RUN_OUT, RUN_ERR.
# Exits 2 if the run was killed or left processes behind: a line may have
# parsed cleanly, so nothing after it can be trusted.
#
# CHECK_DRIFT_CACHE=<dir> (a development aid) keeps each result under
# <dir>/<version>/ and replays it on the next run instead of executing.
run_isolated() {
  guard_argv "$@" || die "run_isolated refused 'agent $*': $REPLY"
  local d key cache=''
  local -a st
  key=${(j:__:)@}
  if [[ -n ${CHECK_DRIFT_CACHE-} ]]; then
    cache=${CHECK_DRIFT_CACHE:A}/$VERSION
    if [[ -r $cache/$key.rc ]]; then
      RUN_RC=$(<$cache/$key.rc) RUN_OUT=$(<$cache/$key.out) RUN_ERR=$(<$cache/$key.err)
      return 0
    fi
  fi
  [[ -n $RUNNER_PL ]] || { new_tmpfile; RUNNER_PL=$REPLY; write_runner >|"$RUNNER_PL" }
  d=$(mktemp -d "${TMPDIR:-/tmp}/check-drift.XXXXXX") || die "mktemp -d failed"
  _TMPDIRS+=("$d")
  mkdir -p -- "$d/home" "$d/tmp" "$d/cwd" || die "cannot populate $d"
  perl -- "$RUNNER_PL" "$d" "$RUN_CAP" "$VERSION_DIR/cursor-agent" "$@"
  case $? in
    0)   ;;
    130) die "interrupted while running 'agent $*'" ;;
    *)   die "the runner failed on 'agent $*'" ;;
  esac
  (( RUN_COUNT++ ))
  st=(${=$(<$d/status)})
  [[ $st[3] == none ]] ||
    die "stopping: 'agent $*' ran into the ${RUN_CAP}s cap and was killed ($st[3]); it may have parsed cleanly"
  (( st[4] == 0 )) || die "stopping: 'agent $*' left processes running in its group (reaped)"
  (( st[2] == 0 )) || die "stopping: 'agent $*' died of signal $st[2]"
  RUN_RC=$st[1] RUN_OUT=$(<$d/out) RUN_ERR=$(<$d/err)
  rm -rf -- "$d"
  _TMPDIRS=("${(@)_TMPDIRS:#$d}")
  if [[ -n $cache ]]; then
    mkdir -p -- "$cache" &&
      print -r -- "$RUN_RC" >|"$cache/$key.rc" &&
      print -r -- "$RUN_OUT" >|"$cache/$key.out" &&
      print -r -- "$RUN_ERR" >|"$cache/$key.err"
  fi
  return 0
}

# --- mined facts, indexed by command path -----------------------------------

typeset -ga MINED_LINES=()
typeset -gA TIER_OF ALIAS_OF KIDS HAS_OPTS HAS_KIDS ARGS_OF ROOT_FLAGS MANDATORY
typeset -gA WALK HELP_USAGE HELP_OPTS HELP_CMDS HELP_KIDS HELP_TEXT ATTR
typeset -ga VALIDATION=()
typeset -gi N_HELP=0 N_PROBES=0

# Registered in isolation: neither gated nor dev-only.
registered_tier() { [[ $1 != (gated:*|dev-only) ]] }

# Why a gated or dev-only entry is never run.
tier_reason() { [[ $1 == dev-only ]] && print -r -- "dev-only: compiled out" || print -r -- "gated: not registered in isolation" }

# The entry's own hidden flag (hidden, or hidden=cond: decided at run time).
own_hidden() { (( ${argv[(Ie)hidden]} || ${argv[(Ie)hidden=cond]} )) }

load_mined() {
  local line p
  local -a F
  local -A argpos
  local k s
  local -i i
  MINED_LINES=("${(@f)$(<$1)}")
  TIER_OF=(agent visible)
  for line in $MINED_LINES; do
    F=("${(@s: | :)line}")
    case $F[1] in
      cmd)
        (( ${F[(Ie)builtin]} )) && continue
        p="$F[2] $F[3]"
        TIER_OF[$p]=$F[4]
        KIDS[$F[2]]+=" $F[3]"
        ALIAS_OF[$p]=${${${(M)F[5,-1]:#aliases=*}#aliases=}%%,*}
        registered_tier $F[4] && HAS_KIDS[$F[2]]=1
        ;;
      opt)
        (( ${F[(Ie)builtin]} )) && continue
        registered_tier $F[4] || continue
        HAS_OPTS[$F[2]]=1
        (( ${F[(Ie)mandatory]} )) && MANDATORY[$F[2]]=$F[3]
        if [[ $F[2] == agent ]]; then
          for p in ${(M)${(s:, :)${F[3]%% [<\[]*}}:#-*}; do ROOT_FLAGS[$p]=1; done
        fi
        ;;
      arg)
        s=${${(M)F[5,-1]:#pos=*}#pos=}
        k="$F[2]|$s"
        argpos[$k]=$F[3]
        ;;
    esac
  done
  # Arguments in position order, as commander prints them.
  for k in ${(k)argpos}; do
    p=${k%\|*}
    [[ -n ${ARGS_OF[$p]-} ]] && continue
    s='' i=1
    while [[ -n ${argpos[$p|$i]-} ]]; do s+=" ${argpos[$p|$i]}"; (( i++ )); done
    ARGS_OF[$p]=${s# }
  done
  guard_init
}

# The flags of an option spec: `-e, --endpoint <url>` -> -e --endpoint.
spec_flags() { reply=(${(M)${(s:, :)${1%% [<\[]*}}:#-*}) }

# Render an attribute value the way the miner does: quoted if it contains a
# space, comma, `|`, `"` or `=`.
attr_val() {
  if [[ $1 == *[[:space:],\|\"=]* ]]; then REPLY="\"${${1//\\/\\\\}//\"/\\\"}\""; else REPLY=$1; fi
}

# has_line <s> <text> / has_word <s> <text>: <s> is a whole line / word of
# <text>. (A nested `${${(f)x}[(Ie)s]}` silently becomes a substring search
# when x has a single line, so lookups go through these.)
has_line() { local -a l=("${(@f)2}"); (( ${l[(Ie)$1]} )) }
has_word() { local -a l=(${=2}); (( ${l[(Ie)$1]} )) }

add_attr() {
  local line=$1 name=$2
  if (( $# > 2 )); then attr_val "$3"; ATTR[$line]+=" | $name=$REPLY"; else ATTR[$line]+=" | $name"; fi
}

# ---------------------------------------------------------------------------
# Help walk
# ---------------------------------------------------------------------------

# Parse one help screen (the lines after its usage line) into HELP_OPTS and
# HELP_CMDS (one term per line: the text before the description column) and
# HELP_KIDS (command names). Commander pads every term to one width, so the
# section's first entry fixes the description column, and a later line is an
# entry only if it has a term at indent two, then at least two spaces of
# padding up to that column. Everything else is description text, which may
# itself contain lines at indent two (a description with raw newlines). Any
# heading ending in "Options:" holds options; other sections (Arguments:,
# addHelpText) are not part of the surface.
parse_help() {
  local p=$1 line section='' term pre
  local -i col=0
  shift
  for line in "$@"; do
    if [[ -z $line ]]; then section='' col=0; continue; fi
    if [[ $line == [A-Z][^:]#: ]]; then section=$line col=0; continue; fi
    [[ $line == '  '[^[:space:]]* ]] || continue
    if (( col == 0 )); then
      term=${${line#  }%%  *}
      pre=${${line#  }#$term}
      col=$(( 2 + ${#term} + ${#${pre%%[^ ]*}} ))
    else
      pre=${line[3,col]}
      term=${pre%%  *}
      [[ ${pre#$term} == '  '(' ')# ]] || (( ${#line} <= col && ${#term} == ${#pre} )) || continue
      [[ ${line[col+1]-} != ' ' ]] || continue
    fi
    case $section in
      *Options:)
        [[ $term == -* ]] && HELP_OPTS[$p]+=$term$'\n' ;;
      Commands:)
        HELP_CMDS[$p]+=$term$'\n'
        HELP_KIDS[$p]+=${${term%% *}%%\|*}$'\n' ;;
    esac
  done
}

# walk_one <path>: run `agent <words> --help` and record WALK[path]:
# own-usage (the output starts with this command's own usage line), or
# fallback (a parent's or the root's usage line: not registered).
walk_one() {
  local p=$1 first pre
  local -a words=(${=p}) lines pw
  shift words
  local -i k
  run_isolated $words --help
  (( N_HELP++ ))
  (( RUN_RC == 0 )) && [[ -z $RUN_ERR ]] ||
    die "stopping: 'agent $words --help' exited $RUN_RC: ${RUN_ERR%%$'\n'*}"
  HELP_TEXT[$p]=$RUN_OUT
  lines=("${(@f)RUN_OUT}")
  first=${lines[1]-}
  # `persist --help` is static text from the pre-commander dispatcher, with
  # its usage on the second line.
  if [[ $p == 'agent persist' ]]; then
    [[ $first == Usage: && ${lines[2]-} == '  agent persist'(| *) ]] ||
      die "stopping: 'agent persist --help' does not start with 'Usage:' / '  agent persist': '$first'"
    WALK[$p]=own-usage
    HELP_USAGE[$p]=${lines[2]#  }
    parse_help "$p" "${(@)lines[3,-1]}"
    return 0
  fi
  if [[ $first == "Usage: $p"(|\|[^ ]##)" [options]"(| *) ]]; then
    WALK[$p]=own-usage
    HELP_USAGE[$p]=${first#Usage: }
    parse_help "$p" "${(@)lines[2,-1]}"
    return 0
  fi
  pw=(${=p})
  for (( k = $#pw - 1; k >= 1; k-- )); do
    pre=${(j: :)pw[1,k]}
    if [[ $first == "Usage: $pre"(|\|[^ ]##)" [options]"(| *) ]]; then
      WALK[$p]=fallback
      return 0
    fi
  done
  die "stopping: 'agent $words --help' printed neither its own usage line nor a parent's: '$first'"
}

# help_walk
# Breadth-first from the root over every child that the miner or a help
# screen reports, children in sorted order. Not walked, with the reason in
# WALK: gated and dev-only commands, the children of `persist`, and the
# builtin `help` commands (their --help prints the parent's help).
help_walk() {
  local -a queue=(agent) kids
  local p kid c
  while (( $#queue )); do
    p=$queue[1]
    shift queue
    walk_one "$p"
    [[ $WALK[$p] == own-usage ]] || continue
    kids=(${=KIDS[$p]-} ${(f)HELP_KIDS[$p]-})
    for kid in ${(ou)kids}; do
      c="$p $kid"
      [[ -n ${WALK[$c]-} || $kid == help ]] && continue
      if [[ $p == 'agent persist' ]]; then
        WALK[$c]='not-walked:persist: dispatched before commander'
        continue
      fi
      case ${TIER_OF[$c]-} in
        gated:*)  WALK[$c]='not-walked:gated: not registered in isolation'; continue ;;
        dev-only) WALK[$c]='not-walked:dev-only: compiled out'; continue ;;
        '')       GUARD_PATHS[$c]=help-listed ;;   # unmined; the validation names it
      esac
      queue+=("$c")
    done
  done
}

# ---------------------------------------------------------------------------
# Probes and classification
# ---------------------------------------------------------------------------
#
# Every record except meta gets exactly one of:
#   help-listed          shown by a walked help screen (option and command
#                        lists, the usage line's arguments)
#   probe=recognized     not listed, but the CLI accepts it: a command whose
#   probe=unknown        --help prints its own usage line, or an option the
#                        probe below does not reject; `unknown` otherwise
#   static-only=<why>    never executed, for the stated reason
# Command records also get walk=own-usage, walk=fallback (not registered), or
# not-walked=<why>. An option probe adds probe-value=none|required, which
# must agree with the mined value=: a disagreement means the miner is wrong.

# probe_flag <path> <flag>: run the option probe; sets REPLY to unknown,
# none (recognized, takes no required value), required, or masked=<spec>.
probe_flag() {
  local p=$1 flag=$2 e1 tok
  local -a words=(${=p})
  shift words
  run_isolated $words $flag --zz-bogus-1 --zz-bogus-2
  (( N_PROBES++ ))
  e1=${RUN_ERR%%$'\n'*}
  (( RUN_RC == 1 )) && [[ -z $RUN_OUT ]] ||
    die "stopping: probe 'agent $words $flag --zz-bogus-1 --zz-bogus-2' exited $RUN_RC (stdout ${RUN_OUT:+not }empty): $e1"
  if [[ $e1 == "error: unknown option '"*"'" ]]; then
    tok=${${e1#*\'}%\'}
    case $tok in
      $flag|$flag=*) REPLY=unknown ;;
      --zz-bogus-1)  REPLY=none ;;
      --zz-bogus-2)  REPLY=required ;;
      *) die "stopping: probe of $flag on '$p' reported unknown option '$tok'" ;;
    esac
  elif [[ $e1 == "error: option '"*"' argument '--zz-bogus-1' is invalid."* || $e1 == 'Error: '* ]]; then
    REPLY=required      # a choices list or a custom parser rejected --zz-bogus-1
  elif [[ $e1 == "error: required option '"*"' not specified" ]]; then
    REPLY="masked=${${e1#*\'}%\'*}"
  else
    die "stopping: probe of $flag on '$p' gave an unexpected result: $e1"
  fi
}

# Why an option on <path> with <flags> may not be probed, in REPLY; or fail.
option_static_reason() {
  local p=$1 a f
  shift
  if [[ -n ${GUARD_NOPROBE[$p]-} ]]; then REPLY=$GUARD_NOPROBE[$p]; return 0; fi
  # A mandatory option on the command or an ancestor fails the line before
  # the unknown-option check.
  for a in ${(k)MANDATORY}; do
    if [[ $p == $a || $p == "$a "* ]]; then
      REPLY="required option ${MANDATORY[$a]} masks unknown options"
      return 0
    fi
  done
  # The root parser consumes its own options anywhere in argv, so a leaf
  # option of the same name can only ever be measured as the root's.
  if [[ $p != agent ]]; then
    for f in "$@"; do
      if (( ${+ROOT_FLAGS[$f]} )); then REPLY="shadowed by root option $f"; return 0; fi
    done
  fi
  for f in "$@"; do
    [[ $f == (-h|--help|-v|--version) ]] && { REPLY="$f exits during parsing"; return 0 }
  done
  return 1
}

classify_opt() {
  local line=$1 p=$2 spec=$3 tier=$4 f r=none res mined
  shift 4
  local -a unknown=()
  if ! registered_tier $tier; then
    add_attr "$line" static-only "$(tier_reason $tier)"; return
  fi
  if [[ $p == 'agent persist'(| *) ]]; then
    add_attr "$line" static-only "persist: dispatched before commander"; return
  fi
  case ${WALK[$p]-} in
    own-usage) ;;
    fallback) add_attr "$line" probe unknown; return ;;
    not-walked:*) add_attr "$line" static-only "${WALK[$p]#not-walked:}"; return ;;
    *) return ;;
  esac
  if has_line "$spec" "${HELP_OPTS[$p]-}"; then add_attr "$line" help-listed; return; fi
  own_hidden "$@" || return          # shown but not listed: the validation reports it
  spec_flags "$spec"
  local -a flags=($reply)
  if option_static_reason "$p" $flags; then add_attr "$line" static-only "$REPLY"; return; fi
  for f in $flags; do
    probe_flag "$p" "$f"
    res=$REPLY
    case $res in
      unknown)  unknown+=($f) ;;
      masked=*) add_attr "$line" static-only "required option ${res#masked=} masks unknown options"; return ;;
      *)        r=$res ;;
    esac
  done
  if (( $#unknown )); then
    add_attr "$line" probe unknown
    (( $#unknown < $#flags )) && add_attr "$line" unknown-flags ${(j:,:)unknown}
    return
  fi
  add_attr "$line" probe recognized
  add_attr "$line" probe-value $r
  mined=${${(M)argv:#value=*}#value=}
  [[ ${mined/optional/none} == $r ]] ||
    VALIDATION+=("$p: option '$spec' is mined as value=$mined, but the probe finds value=$r")
}

classify_cmd() {
  local line=$1 parent=$2 name=$3 tier=$4 c="$2 $3"
  shift 4
  if ! registered_tier $tier; then
    add_attr "$line" static-only "$(tier_reason $tier)"
    add_attr "$line" not-walked "$(tier_reason $tier)"
    return
  fi
  if (( ${argv[(Ie)builtin]} )); then
    if [[ $parent == 'agent persist' ]]; then
      add_attr "$line" static-only "persist: dispatched before commander"
    elif [[ ${WALK[$parent]-} != own-usage ]]; then
      add_attr "$line" static-only "parent not walked"
    elif has_line "$name" "${HELP_KIDS[$parent]-}"; then
      add_attr "$line" help-listed
    fi
    add_attr "$line" not-walked "builtin: prints the parent's help"
    return
  fi
  case ${WALK[$c]-} in
    not-walked:*)
      add_attr "$line" static-only "${WALK[$c]#not-walked:}"
      add_attr "$line" not-walked "${WALK[$c]#not-walked:}"
      return ;;
    '')
      add_attr "$line" static-only "parent not walked"
      add_attr "$line" not-walked "parent not walked"
      return ;;
  esac
  if has_line "$name" "${HELP_KIDS[$parent]-}"; then
    add_attr "$line" help-listed
  elif [[ $WALK[$c] == own-usage ]]; then
    add_attr "$line" probe recognized
  else
    add_attr "$line" probe unknown
  fi
  add_attr "$line" walk $WALK[$c]
}

classify_arg() {
  local line=$1 p=$2 spec=$3 tier=$4 term
  if ! registered_tier $tier; then
    add_attr "$line" static-only "$(tier_reason $tier)"; return
  fi
  if [[ $p == 'agent persist '* ]]; then
    add_attr "$line" static-only "persist: dispatched before commander"; return
  fi
  if [[ ${WALK[$p]-} == own-usage ]] && has_word "$spec" "$HELP_USAGE[$p]"; then
    add_attr "$line" help-listed; return
  fi
  # The parent's command list shows each child's arguments (the builtin
  # `help [command]` is only ever seen there).
  for term in ${(f)HELP_CMDS[${p% *}]-}; do
    if [[ ${${term%% *}%%\|*} == ${p##* } ]] && has_word "$spec" "$term"; then
      add_attr "$line" help-listed; return
    fi
  done
  [[ ${WALK[$p]-} == not-walked:* ]] && add_attr "$line" static-only "${WALK[$p]#not-walked:}"
}

classify_other() {
  local line=$1 kind=$2 p=$3 name=$4 value=${6-}
  case $kind in
    enum)    add_attr "$line" static-only "validator outside commander" ;;
    prescan) add_attr "$line" static-only "raw-argv prescan without a registration" ;;
    grammar)
      if [[ $p == 'agent persist' && $name == usage ]] &&
         has_line "  $value" "${HELP_TEXT[$p]-}"; then
        add_attr "$line" help-listed
      elif [[ $p == 'agent persist' ]]; then
        add_attr "$line" static-only "persist: dispatched before commander"
      else
        add_attr "$line" static-only "argv rewrite before commander"
      fi ;;
  esac
}

# run_probes
# Classify every mined record (see above), probing what no help screen shows.
run_probes() {
  local line
  local -a F
  for line in $MINED_LINES; do
    F=("${(@s: | :)line}")
    case $F[1] in
      opt)  classify_opt "$line" "${(@)F[2,-1]}" ;;
      cmd)  classify_cmd "$line" "${(@)F[2,-1]}" ;;
      arg)  classify_arg "$line" "${(@)F[2,-1]}" ;;
      meta) ;;
      *)    classify_other "$line" "${(@)F}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Self-validation
# ---------------------------------------------------------------------------

# Compare two newline-separated sets; record differences in VALIDATION.
compare_sets() {
  local where=$1 what=$2 x
  local -a mined=(${(f)3}) listed=(${(f)4})
  for x in ${(o)listed}; do
    (( ${mined[(Ie)$x]} )) || VALIDATION+=("$where: help lists $what '$x', which the miner does not report as shown")
  done
  for x in ${(o)mined}; do
    (( ${listed[(Ie)$x]} )) || VALIDATION+=("$where: the miner reports $what '$x' as shown, but help does not list it")
  done
}

# validate_mined_vs_help
# The miner reads minified bundle shapes, so it is checked against the
# second, independent source on every run: on each walked screen, the listed
# options (full spec, so the value shape too), the listed commands (name,
# first alias, `[options]` if it has any, arguments) and the usage line
# (alias, `[command]`, arguments) must equal what the mined records predict.
# A `hidden=cond` entry may go either way and is left out on both sides.
# Any difference exits 2 with "miner needs attention", naming the entries.
validate_mined_vs_help() {
  local p line want c term listed_cmds listed_opts
  local -a F lines usages
  local -A mopts mcmds cond
  for line in $MINED_LINES; do
    F=("${(@s: | :)line}")
    [[ $F[1] == (opt|cmd) ]] && registered_tier $F[4] || continue
    if (( ${F[(Ie)hidden=cond]} )); then c="$F[1]|$F[2]|$F[3]"; cond[$c]=1; continue; fi
    own_hidden "${(@)F[5,-1]}" && continue
    if [[ $F[1] == opt ]]; then
      mopts[$F[2]]+=$F[3]$'\n'
    else
      c="$F[2] $F[3]"
      term=$F[3]${ALIAS_OF[$c]:+|$ALIAS_OF[$c]}
      (( ${+HAS_OPTS[$c]} )) && term+=' [options]'
      [[ -n ${ARGS_OF[$c]-} ]] && term+=" $ARGS_OF[$c]"
      mcmds[$F[2]]+=$term$'\n'
    fi
  done
  for p in ${(ok)WALK}; do
    case $WALK[$p] in
      own-usage) ;;
      fallback)
        VALIDATION+=("$p: the miner reports this command, but its --help falls back to a parent's (not registered)")
        continue ;;
      *) continue ;;
    esac
    if [[ -z ${TIER_OF[$p]-} ]]; then
      VALIDATION+=("$p: help lists this command, which the miner does not report")
      continue
    fi
    if [[ $p == 'agent persist' ]]; then
      # Static text: its usage lines must be the mined persist grammar.
      usages=()
      lines=(${(M)${(f)HELP_TEXT[$p]}:#  agent persist*})
      for line in $MINED_LINES; do
        [[ $line == 'grammar | agent persist | usage | '* ]] && usages+=("  ${${(s: | :)line}[5]}")
      done
      compare_sets "$p" "usage line" "${(F)usages}" "${(F)lines}"
      continue
    fi
    want="$p${ALIAS_OF[$p]:+|$ALIAS_OF[$p]} [options]"
    (( ${+HAS_KIDS[$p]} )) && want+=' [command]'
    [[ -n ${ARGS_OF[$p]-} ]] && want+=" $ARGS_OF[$p]"
    [[ $HELP_USAGE[$p] == $want ]] ||
      VALIDATION+=("$p: usage line is '$HELP_USAGE[$p]', the miner predicts '$want'")
    listed_cmds='' listed_opts=''
    for term in ${(f)HELP_CMDS[$p]-}; do
      (( ${+cond[cmd|$p|${${term%% *}%%\|*}]} )) || listed_cmds+=$term$'\n'
    done
    for term in ${(f)HELP_OPTS[$p]-}; do
      (( ${+cond[opt|$p|$term]} )) || listed_opts+=$term$'\n'
    done
    compare_sets "$p" option "${mopts[$p]-}" "$listed_opts"
    compare_sets "$p" command "${mcmds[$p]-}" "$listed_cmds"
  done
  # Every record must have been classified. (A shown entry missing from a
  # compared screen is unclassified too, but already reported above.)
  for line in $MINED_LINES; do
    [[ $line == 'meta | '* || -n ${ATTR[$line]-} ]] && continue
    F=("${(@s: | :)line}")
    p=$F[2]
    [[ $F[1] == arg ]] && p=${p% *}       # an argument is also checked on its parent's screen
    if [[ $F[1] == (opt|cmd|arg) && $p != 'agent persist'(| *) && ${WALK[$p]-} == own-usage ]] &&
       ! own_hidden "${(@)F[5,-1]}"; then
      continue
    fi
    VALIDATION+=("$F[2]: record not classified: $line")
  done
  if (( $#VALIDATION )); then
    print -ru2 -- "check-drift: miner needs attention: the mined surface and the help walk disagree:"
    print -ru2 -l -- "  "${^VALIDATION}
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Dump builder and modes
# ---------------------------------------------------------------------------

build_dump() {
  local mined line
  print -r -- "# Cursor CLI surface, generated by tools/check-drift.zsh"
  print -r -- "# Do not hand-edit; regenerate with: zsh tools/check-drift.zsh snapshot"
  new_tmpfile; mined=$REPLY
  mine_static "$VERSION_DIR" >|"$mined"
  if (( STATIC_ONLY )); then
    cat -- "$mined"
    return 0
  fi
  load_mined "$mined"
  help_walk
  run_probes
  validate_mined_vs_help
  for line in $MINED_LINES; do print -r -- "$line${ATTR[$line]-}"; done | sort
  local -a a=("${(@v)ATTR}")
  local -i nr=${#${(M)a:#* probe=recognized*}} nu=${#${(M)a:#* probe=unknown*}} ns=${#${(M)a:#* static-only=*}}
  print -ru2 -- "check-drift: $N_HELP help screens, $N_PROBES option probes; records:" \
    "$nr probe=recognized, $nu probe=unknown, $ns static-only; $RUN_COUNT CLI executions"
}

not_implemented() {
  die "not implemented: $1 (only dump exists so far)"
}

mode_check()    { not_implemented "check mode" }
mode_snapshot() { not_implemented "snapshot mode" }
# diff <old-version-dir> <new-version-dir>: dump both, diff grouped by path.
mode_diff()     { not_implemented "diff mode" }

usage() {
  local line
  while IFS= read -r line; do
    [[ $line == '#!'* ]] && continue
    [[ $line == '#'* ]] || break
    line=${line#\#}
    print -r -- "${line# }"
  done <"$SCRIPT_PATH"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local mode=''
  local -a rest=()
  while (( $# )); do
    case $1 in
      --version-dir)
        (( $# >= 2 )) || die "--version-dir needs a path"
        OPT_VERSION_DIR=$2
        shift 2
        ;;
      --version-dir=*) OPT_VERSION_DIR=${1#*=}; shift ;;
      --static)        STATIC_ONLY=1; shift ;;
      -h|--help|help)  usage; return 0 ;;
      -*)              die "unknown option '$1'" ;;
      *)
        if [[ -z $mode ]]; then mode=$1; else rest+=("$1"); fi
        shift
        ;;
    esac
  done
  mode=${mode:-check}

  case $mode in
    dump)
      (( ${#rest} == 0 )) || die "dump takes no arguments"
      locate_version_dir
      # Into a file first, so a failure partway prints nothing. A function
      # with a redirection still runs in this shell, so its exits are ours.
      local tmp; new_tmpfile; tmp=$REPLY
      build_dump >|"$tmp"
      cat -- "$tmp"
      ;;
    check|snapshot)
      (( ${#rest} == 0 )) || die "$mode takes no arguments"
      mode_$mode
      ;;
    diff)
      (( ${#rest} == 2 )) || die "usage: zsh tools/check-drift.zsh diff <old-version-dir> <new-version-dir>"
      mode_diff "${rest[@]}"
      ;;
    *)
      die "unknown mode '$mode' (expected: check | snapshot | dump | diff)"
      ;;
  esac
}

main "$@"
