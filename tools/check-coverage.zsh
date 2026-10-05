#!/usr/bin/env zsh
#
# check-coverage.zsh: compare the completion script (src/_cursor-agent) with
# the CLI surface snapshot (tools/cli-surface.txt), in both directions, and
# report every entry the script lacks, gets wrong, or completes beyond the
# snapshot.
#
# MAINTAINERS: run this after `zsh tools/check-drift.zsh snapshot` (runbook in
# CLAUDE.md). Snapshot drift says what changed in the CLI; this tool says what
# the script still lacks. It never runs `agent` and never sources or executes
# the script: both files are parsed as text, so it needs no binary and runs in
# CI and in the test preflight.
#
# Usage:
#   zsh tools/check-coverage.zsh [options]
#   zsh tools/check-coverage.zsh -h | --help
#
# Options:
#   --script <file>      completion script to check (default: src/_cursor-agent)
#   --snapshot <file>    CLI surface snapshot (default: tools/cli-surface.txt)
#   --exceptions <file>  deliberate deviations (default:
#                        tools/coverage-exceptions.txt; a missing file means
#                        no exceptions)
#   -q, --quiet          print only the final summary line (and, on exit 2,
#                        the error)
#
# Defaults resolve relative to this tool's own location, so it works from any
# directory.
#
# Exit codes: 0 = script and snapshot agree (every finding is covered by an
# exception, and no exception is stale), 1 = coverage gaps (findings or stale
# exceptions), 2 = the tool itself could not run: a missing file, a bad
# argument, a snapshot record it does not understand, or a script shape the
# parser cannot read. 2 wins: no report is printed after it, so a parse
# failure can never pass silently.
#
# Finding lines, grouped by function (blank line between groups):
#
#   <function> (<command path>): <code> <entry>: <detail>
#
# <entry> is a long option name (`--endpoint`), a positional slot (`arg1`,
# `arg*` for the rest slot), a subcommand name, or `target-version`. Codes:
#   function-missing   no function for a command path in the snapshot
#   function-extra     a _cursor_agent* function no snapshot path maps to
#   opt-missing        an option the snapshot has and the script lacks
#   opt-extra          an option the script completes that the snapshot lacks
#   opt-alias          alias pairing differs (`-e, --endpoint` is one brace
#                      pair, `{-e,--endpoint}`; separate options are not)
#   opt-value          boolean / required value (`:`) / optional value (`::`)
#   opt-repeat         repeatable in the snapshot (`*` prefix) or not
#   opt-conflict       one function specifies the same flag two ways
#   enum-missing       the snapshot has values, the script completes none
#   enum-extra         the script completes values, the snapshot has none
#   enum-values        both have values, and the sets differ
#   arg-missing        a positional slot the snapshot has and the script lacks
#   arg-extra          a positional slot the snapshot lacks
#   cmd-missing        a subcommand (or alias) absent from the roster
#   cmd-extra          a roster entry the snapshot lacks
#   cmd-tag            an entry in the wrong _describe tag (see below)
#   cmd-dup            an entry listed more than once
#   dispatch-missing   no `case $words[1]` arm for a subcommand (or alias)
#   dispatch-target    the arm calls something other than the subcommand's
#                      function
#   dispatch-extra     an arm for a word that is not a subcommand
#   excl-unknown       an exclusion group names a flag the function lacks
#   dev-only           a tier 4 (dev-only, compiled out) entry is present
#   target-version     the header's "# Target: Cursor CLI <v>" differs from
#                      the snapshot's version record
# Stale exceptions are reported as `exception-unused` lines naming the
# exceptions file and line.
#
# Exceptions file: one deviation per line, fields joined by " | ":
#
#   <function> | <code> | <entry> | <reason>
#
# The first three fields must match a finding exactly; the reason is
# required. Blank lines and lines starting with `#` are ignored.
#
# What is compared, per command path P and its function F(P):
#   - Options: every `opt` record of P (all tiers but dev-only) against the
#     `_arguments` option specs of F(P): names and alias pairs, value kind,
#     repeatable, and enum values (`choices=` or an `enum` record for the
#     option, against an inline `:label:(a b c)` action).
#   - Positionals: `arg` records (`<x>`, `[x]` at pos=n: a numbered `n:` spec;
#     a variadic `[x...]`: a `*:` spec) and their `enum` values. Required
#     versus optional positionals are not compared (`N:` versus `N::` makes
#     no visible difference for these commands).
#   - Subcommands: `cmd` children of P and their aliases against the
#     `_describe` rosters in F(P) and F(P)_commands, and against the
#     `case $words[1]` (or `$line[1]`) dispatch arms of F(P). The expected
#     tag: an entry with its own `hidden` flag (`hidden`, `hidden=cond`) goes
#     in `hidden-commands`; an entry whose own tier is gated (the gated
#     commands and every subcommand inside a gated tree) goes in
#     `gated-commands`; everything else, including the children of a hidden
#     command, goes in `commands`.
#   - Dev-only (tier 4) commands, options and grammar flags must be absent:
#     roster entries, dispatch arms, functions and option specs for them are
#     `dev-only` findings.
#
# Deliberate treatments:
#   - `conditional` entries (registered behind a runtime condition that is
#     neither a gate nor dev-only, such as `team` outside local mode) are
#     compared like any other entry of their tier: they exist in a normal
#     session, so the script completes them in their tier's tag.
#   - Exclusion groups (`(-f --force --yolo)`, `(--mode --plan)`, ...) are
#     editorial and are NOT compared with the snapshot's `conflicts=`
#     attributes; the only check is that every flag a group names exists in
#     the same function (excl-unknown).
#   - `grammar` records (hand-rolled argv handling before commander):
#       usage           `agent persist [options] [prompt...]` and the like:
#                       `[options]` means F(P) must also offer every root
#                       option (presence only; their details are compared at
#                       the root, where they are defined); positional words
#                       add positional slots, merged with `arg` records.
#       subcommand      a roster entry, merged with `cmd` records.
#       help-flag       an option, merged with `opt` records.
#       dev-only flags  (`restore-marker`) must be absent from F(P).
#       pool-*          the `worker --pool` argv rewrite: informational only;
#                       the options themselves are `opt` records.
#     Any other grammar kind, or any record kind besides cmd, opt, arg, enum,
#     grammar and meta, stops the tool with exit 2: decide how to compare it,
#     then teach this tool.
#   - Commander's builtin `help` subcommand is a roster entry like any other,
#     with its own function (F(`agent mcp help`) is _cursor_agent_mcp_help).
#
# Script shapes the parser reads (anything else that it cannot read is exit 2):
#   - Functions `name() { ... }` (or `function name { ... }`), one-liners
#     included. Every _cursor_agent* function must map to a command path
#     (F(P)) or be the roster helper F(P)_commands of a path with
#     subcommands; any other is function-extra (list helpers as exceptions).
#   - `_arguments` calls, backslash-continued, with leading _arguments flags
#     (-C -s -S -w -W -n -0 -R; -A, -M, -O take a value), whose words are
#     single or double quoted spec pieces, inline brace pairs, and references
#     to arrays (`$name`, `"${name[@]}"`, `${(@)name}`). Arrays come from
#     `name=(...)` / `local name=(...)` / `name+=(...)` in the same function,
#     or, by zsh's dynamic scoping, from the one function that defines the
#     name (the root's `global_options`, reused by `persist`). Comments may
#     sit between specs. A word with any other parameter expansion is exit 2.
#   - Dispatch: an `_arguments -C` call whose subcommand slot is
#     `1: :F(P)_commands` or `N: :->state`, and `*:: :->state`; these are not
#     positionals. `case $words[1] in` (or `$line[1]`) arms, alias arms such
#     as `status|whoami)`, each calling the subcommand's function. Only the
#     fallback arm `*)` may hold `_arguments` or `_describe` itself; a
#     per-subcommand spec inside a named arm is exit 2 (move it into that
#     subcommand's function).
#   - Rosters: `_describe -t <tag> '<description>' <array>` over arrays of
#     `name:description` entries (`\:` escapes a colon in the name), or
#     `_cursor_agent_describe_groups` with `<tag> '<description>' <array>`
#     triples over the same kind of arrays.

emulate -L zsh
setopt extended_glob no_unset pipe_fail
export LC_ALL=C

# Capture at file scope: inside a function, $0 is the function's name.
typeset -g SCRIPT_PATH=${0:A}
typeset -g REPO_DIR=${SCRIPT_PATH:h:h}
typeset -g SCRIPT_FILE=$REPO_DIR/src/_cursor-agent
typeset -g SNAPSHOT=${SCRIPT_PATH:h}/cli-surface.txt
typeset -g EXCEPTIONS=${SCRIPT_PATH:h}/coverage-exceptions.txt
typeset -gi QUIET=0

die() { print -ru2 -- "check-coverage: $*"; exit 2 }

# NOTE: never name a local `path` in this file. zsh ties `path` to `PATH`, so a
# `local path=...` silently wipes the command search path for that function's
# whole dynamic scope. Use `cmdpath`.

# ---------------------------------------------------------------------------
# The checker
# ---------------------------------------------------------------------------

# The checker is perl: one pass over each file, well under a second. It takes
# <script> <snapshot> <exceptions-or-empty> <quiet>, prints the report, and
# exits 0, 1 or 2 as documented above.
write_checker() {
  cat <<'PERL'
use strict;
use warnings;

my ($SCRIPT, $SNAP, $EXC, $QUIET) = @ARGV;

sub fail { print STDERR "check-coverage: $_[0]\n"; exit 2 }

sub slurp {
  my $f = shift;
  open my $fh, '<', $f or fail("cannot read $f: $!");
  local $/;
  my $t = <$fh>;
  close $fh;
  return $t;
}

# Completion function for a command path (as path_function in check-drift.zsh):
# `agent plugin marketplace add` -> _cursor_agent_plugin_marketplace_add.
sub fname {
  my $p = shift;
  $p =~ s/^agent\s*//;
  $p =~ s/-/_/g;
  $p =~ s/ /_/g;
  return '_cursor_agent' . ($p eq '' ? '' : "_$p");
}

# ===========================================================================
# Snapshot
# ===========================================================================

# Fields are joined by " | "; attribute values with spaces, commas, `|`, `"`
# or `=` are double-quoted with `\` escapes, so split outside quotes only.
sub split_fields {
  my $l = shift;
  my (@f, $cur, $inq);
  $cur = ''; $inq = 0;
  for (my $i = 0; $i < length $l; $i++) {
    my $c = substr($l, $i, 1);
    if ($inq && $c eq '\\') { $cur .= substr($l, $i, 2); $i++; next }
    if ($c eq '"') { $inq = !$inq; $cur .= $c; next }
    if (!$inq && substr($l, $i, 3) eq ' | ') { push @f, $cur; $cur = ''; $i += 2; next }
    $cur .= $c;
  }
  push @f, $cur;
  return @f;
}

sub attrs {
  my %a;
  for my $x (@_) {
    if ($x =~ /^([\w-]+)=(.*)$/s) {
      my ($k, $v) = ($1, $2);
      if ($v =~ /^"(.*)"$/s) { $v = $1; $v =~ s/\\n/\n/g; $v =~ s/\\(.)/$1/g }
      $a{$k} = $v;
    } else {
      $a{$_} = 1 for split ' ', $x;   # `optional variadic` is one field
    }
  }
  return \%a;
}

sub spec_flags {
  my $s = shift;
  $s =~ s/ [<\[].*//s;
  return grep { /^-/ } split /, /, $s;
}

my %PATH;       # path -> { tier, attrs }
my %CHILD;      # path -> name -> { tier, aliases => [], hidden, builtin }
my %DEVCHILD;   # path -> name -> 1
my %DEVPATH;    # path -> 1
my %OPT;        # path -> [ { flags => [], value, choices => [] or undef, rep, spec } ]
my %DEVOPT;     # path -> flag -> 1
my %ARG;        # path -> pos ('n' or '*') -> { name, pos }
my %ENUM;       # path -> name -> [values]
my %INHERIT;    # path -> usage text that grants the root options
my $VERSION = '';
my $NREC = 0;

$PATH{agent} = { tier => 'visible', attrs => {} };

my @recs;
{
  my $ln = 0;
  for my $l (split /\n/, slurp($SNAP)) {
    $ln++;
    next if $l =~ /^#/ || $l =~ /^\s*$/;
    my @f = split_fields($l);
    fail("$SNAP:$ln: malformed record (fewer than 4 fields): $l") if @f < 4;
    push @recs, [$ln, @f];
    $NREC++;
  }
}
fail("$SNAP has no records") unless $NREC;

# Pass 1: commands (so every other record can be checked against a known path).
for my $r (sort { $a->[2] cmp $b->[2] || $a->[3] cmp $b->[3] } grep { $_->[1] eq 'cmd' } @recs) {
  my ($ln, $kind, $parent, $name, $tier, @rest) = @$r;
  my $a = attrs(@rest);
  my $p = "$parent $name";
  if ($tier eq 'dev-only') {
    $DEVPATH{$p} = 1;
    $DEVCHILD{$parent}{$name} = 1;
    next;
  }
  next if $DEVPATH{$parent};
  fail("$SNAP:$ln: cmd record under unknown parent '$parent'") unless $PATH{$parent};
  $PATH{$p} = { tier => $tier, attrs => $a };
  $CHILD{$parent}{$name} = {
    tier    => $tier,
    aliases => [defined $a->{aliases} ? split(/,/, $a->{aliases}) : ()],
    hidden  => (exists $a->{hidden} ? 1 : 0),
    builtin => (exists $a->{builtin} ? 1 : 0),
  };
}

sub known_path {
  my ($p, $ln) = @_;
  return 0 if $DEVPATH{$p};
  fail("$SNAP:$ln: record for unknown command path '$p'") unless $PATH{$p};
  return 1;
}

# Pass 2: everything else; grammar last, since it merges into opt and arg data.
for my $r ((grep { $_->[1] ne 'grammar' } @recs), (grep { $_->[1] eq 'grammar' } @recs)) {
  my ($ln, $kind, $p, $name, $tier, @rest) = @$r;
  my $a = attrs(@rest);
  if ($kind eq 'cmd') {
    next;
  } elsif ($kind eq 'opt') {
    my @fl = spec_flags($name);
    fail("$SNAP:$ln: option spec without flags: $name") unless @fl;
    if ($tier eq 'dev-only') { $DEVOPT{$p}{$_} = 1 for @fl; next }
    next unless known_path($p, $ln);
    fail("$SNAP:$ln: option record without value=: $name") unless defined $a->{value};
    fail("$SNAP:$ln: unknown value kind '$a->{value}'") unless $a->{value} =~ /^(none|required|optional)$/;
    push @{$OPT{$p}}, {
      flags   => \@fl,
      value   => $a->{value},
      choices => (defined $a->{choices} ? [split /,/, $a->{choices}] : undef),
      rep     => (exists $a->{repeatable} ? 1 : 0),
      spec    => $name,
      tier    => $tier,
    };
  } elsif ($kind eq 'arg') {
    next if $tier eq 'dev-only';
    next unless known_path($p, $ln);
    fail("$SNAP:$ln: arg record without pos=: $name") unless defined $a->{pos} && $a->{pos} =~ /^\d+$/;
    my $slot = exists $a->{variadic} ? '*' : $a->{pos};
    $ARG{$p}{$slot} = { name => $name, slot => $slot };
  } elsif ($kind eq 'enum') {
    next if $tier eq 'dev-only';
    next unless known_path($p, $ln);
    fail("$SNAP:$ln: enum record without values=") unless defined $a->{values};
    $ENUM{$p}{$name} = [split /,/, $a->{values}];
  } elsif ($kind eq 'grammar') {
    # grammar | <path> | <kind> | <tier> | <value> | ...
    my $g = $name;
    my $v = $rest[0] // '';
    if ($tier eq 'dev-only') {
      fail("$SNAP:$ln: dev-only grammar record whose value is not a flag: $v") unless $v =~ /^-/;
      $DEVOPT{$p}{$_} = 1 for split /,/, $v;
      next;
    }
    next unless known_path($p, $ln);
    if ($g eq 'subcommand') {
      $CHILD{$p}{$v} //= { tier => $tier, aliases => [], hidden => 0, builtin => 0 };
      $PATH{"$p $v"} //= { tier => $tier, attrs => {} };
    } elsif ($g eq 'help-flag') {
      my $have = grep { grep { $_ eq $v } @{$_->{flags}} } @{$OPT{$p} || []};
      push @{$OPT{$p}}, { flags => [$v], value => 'none', choices => undef, rep => 0, spec => $v, tier => $tier } unless $have;
    } elsif ($g eq 'usage') {
      my @w = split ' ', $v;
      my @pw = split ' ', $p;
      fail("$SNAP:$ln: usage '$v' does not start with '$p'") unless "@w[0..$#pw]" eq "@pw";
      splice @w, 0, scalar @pw;
      my $up = $p;
      if (@w && $w[0] !~ /^[<\[]/) {
        fail("$SNAP:$ln: usage '$v' names unknown subcommand '$w[0]'") unless $CHILD{$p}{$w[0]};
        $up = "$p " . shift @w;
      }
      my $pos = 0;
      for my $t (@w) {
        if ($t eq '[options]') { $INHERIT{$up} = $v; next }
        fail("$SNAP:$ln: usage word '$t' not understood") unless $t =~ /^(<[^>]+>|\[[^\]]+\])$/;
        $pos++;
        my $slot = $t =~ /\.\.\.[>\]]$/ ? '*' : $pos;
        $ARG{$up}{$slot} //= { name => $t, slot => $slot };
      }
    } elsif ($g =~ /^pool-/) {
      # Informational: the argv rewrite of worker --pool.
    } else {
      fail("$SNAP:$ln: unknown grammar kind '$g'; decide how to compare it, then teach this tool");
    }
  } elsif ($kind eq 'meta') {
    $VERSION = $rest[0] if $name eq 'version';
  } else {
    fail("$SNAP:$ln: unknown record kind '$kind'; decide how to compare it, then teach this tool");
  }
}

# ===========================================================================
# Script lexer: zsh words, quotes, comments, continuations
# ===========================================================================

my $SRC = slurp($SCRIPT);
my @T;          # [type, value, line]; W value: [ [kind, text, exp], ... ]
{
  my ($i, $n, $line) = (0, length $SRC, 1);
  my $peek = sub { substr($SRC, $_[0], 1) };
  # Read a balanced ${...} or $(...) starting at $j (on the opener); returns
  # the end index (past the closer).
  my $balanced = sub {
    my ($j, $open, $close) = @_;
    my $d = 0;
    while ($j < $n) {
      my $c = substr($SRC, $j, 1);
      if ($c eq '\\') { $j += 2; next }
      if ($c eq "'") { my $k = index($SRC, "'", $j + 1); fail("$SCRIPT:$line: unterminated quote") if $k < 0; $j = $k + 1; next }
      $line++ if $c eq "\n";
      $d++ if $c eq $open;
      if ($c eq $close) { $d--; return $j + 1 if $d == 0 }
      $j++;
    }
    fail("$SCRIPT:$line: unterminated '$open'");
  };
  while ($i < $n) {
    my $c = substr($SRC, $i, 1);
    if ($c eq "\n") { push @T, ['NL', undef, $line]; $line++; $i++; next }
    if ($c eq ' ' || $c eq "\t") { $i++; next }
    if ($c eq '\\' && $peek->($i + 1) eq "\n") { $i += 2; $line++; next }
    if ($c eq '#') { $i++ while $i < $n && substr($SRC, $i, 1) ne "\n"; next }
    if ($c eq ';') {
      if ($peek->($i + 1) =~ /^[;&|]$/) { push @T, ['SEMI2', undef, $line]; $i += 2 }
      else { push @T, ['SEP', ';', $line]; $i++ }
      next;
    }
    if ($c eq '&') { push @T, ['SEP', '&', $line]; $i += ($peek->($i + 1) eq '&') ? 2 : 1; next }
    if ($c eq '|') {
      if ($peek->($i + 1) eq '|') { push @T, ['SEP', '||', $line]; $i += 2 }
      else { push @T, ['PIPE', '|', $line]; $i++ }
      next;
    }
    if ($c eq '(') {
      if ($peek->($i + 1) eq '(') {          # (( arithmetic )): opaque
        my $k = index($SRC, '))', $i + 2);
        fail("$SCRIPT:$line: unterminated (( ))") if $k < 0;
        $line += (substr($SRC, $i, $k - $i) =~ tr/\n//);
        push @T, ['SEP', '((', $line];
        $i = $k + 2;
        next;
      }
      push @T, ['LP', '(', $line]; $i++; next;
    }
    if ($c eq ')') { push @T, ['RP', ')', $line]; $i++; next }

    # A word.
    my @seg;
    my $wline = $line;
    my $bare = sub {
      if (@seg && $seg[-1][0] eq 'b') { $seg[-1][1] .= $_[0]; $seg[-1][2] ||= $_[1] }
      else { push @seg, ['b', $_[0], $_[1]] }
    };
    my $assign;
    while ($i < $n) {
      $c = substr($SRC, $i, 1);
      if ($c eq '(') {
        my $sofar = join '', map { $_->[0] eq 'b' ? $_->[1] : "\0" } @seg;
        if ($sofar =~ /^([A-Za-z_]\w*)(\+?)=$/) { $assign = [$1, $2]; $i++; last }
        last;
      }
      last if $c =~ /^[ \t\n;&|)]$/;
      if ($c eq "'") {
        my $k = index($SRC, "'", $i + 1);
        fail("$SCRIPT:$line: unterminated single quote") if $k < 0;
        my $t = substr($SRC, $i + 1, $k - $i - 1);
        $line += ($t =~ tr/\n//);
        push @seg, ['q', $t, 0];
        $i = $k + 1;
      } elsif ($c eq '"') {
        my ($t, $exp) = ('', 0);
        $i++;
        while (1) {
          fail("$SCRIPT:$wline: unterminated double quote") if $i >= $n;
          my $d = substr($SRC, $i, 1);
          if ($d eq '"') { $i++; last }
          if ($d eq '\\') {
            my $e = $peek->($i + 1);
            if ($e eq "\n") { $line++ }
            elsif ($e =~ /^[\$`"\\]$/) { $t .= $e }
            else { $t .= "\\$e" }
            $i += 2;
            next;
          }
          if ($d eq '$' || $d eq '`') { $exp = 1 }
          $line++ if $d eq "\n";
          $t .= $d;
          $i++;
        }
        push @seg, ['d', $t, $exp];
      } elsif ($c eq '$' && $peek->($i + 1) eq "'") {
        my ($t, $j) = ('', $i + 2);
        while (1) {
          fail("$SCRIPT:$wline: unterminated \$'...'") if $j >= $n;
          my $d = substr($SRC, $j, 1);
          last if $d eq "'";
          if ($d eq '\\') {
            my $e = substr($SRC, $j + 1, 1);
            $t .= $e eq 'n' ? "\n" : $e eq 't' ? "\t" : $e;
            $j += 2;
            next;
          }
          $t .= $d;
          $j++;
        }
        push @seg, ['q', $t, 0];
        $i = $j + 1;
      } elsif ($c eq '$' && $peek->($i + 1) =~ /^[{(]$/) {
        my $o = $peek->($i + 1);
        my $k = $balanced->($i + 1, $o, $o eq '{' ? '}' : ')');
        $bare->(substr($SRC, $i, $k - $i), 1);
        $i = $k;
      } elsif ($c eq '$') {
        $bare->('$', 1);
        $i++;
      } elsif ($c eq '`') {
        fail("$SCRIPT:$line: backquote command substitution is not supported");
      } elsif ($c eq '\\') {
        my $e = $peek->($i + 1);
        if ($e eq "\n") { $line++; $i += 2; next }
        push @seg, ['q', $e, 0];
        $i += 2;
      } elsif ($c eq '<' && $peek->($i + 1) eq '<') {
        fail("$SCRIPT:$line: here-documents are not supported");
      } else {
        $bare->($c, 0);
        $i++;
      }
    }
    if ($assign) {
      push @T, ['ASSIGN', $assign, $wline];
      next;
    }
    next unless @seg;
    if (@seg == 1 && $seg[0][0] eq 'b' && $seg[0][1] eq '{') { push @T, ['LB', '{', $wline]; next }
    if (@seg == 1 && $seg[0][0] eq 'b' && $seg[0][1] eq '}') { push @T, ['RB', '}', $wline]; next }
    push @T, ['W', \@seg, $wline];
  }
}

# Plain text of a word (quotes removed, expansions kept verbatim).
sub wtext { join '', map { $_->[1] } @{$_[0]} }
sub wexp { scalar grep { $_->[2] } @{$_[0]} }
sub wraw {
  join '', map { $_->[0] eq 'q' ? "'$_->[1]'" : $_->[0] eq 'd' ? "\"$_->[1]\"" : $_->[1] } @{$_[0]};
}

# ===========================================================================
# Script parser: functions, arrays, commands, case arms
# ===========================================================================

my %FN;         # name -> { line, body => [tokens] }
my @FNORDER;
{
  my $j = 0;
  while ($j < @T) {
    my $t = $T[$j];
    my ($name, $k);
    if ($t->[0] eq 'W' && !wexp($t->[1]) && $j + 2 < @T && $T[$j + 1][0] eq 'LP' && $T[$j + 2][0] eq 'RP') {
      $name = wtext($t->[1]); $k = $j + 3;
    } elsif ($t->[0] eq 'W' && wtext($t->[1]) eq 'function' && $j + 1 < @T && $T[$j + 1][0] eq 'W') {
      $name = wtext($T[$j + 1][1]); $k = $j + 2;
      $k += 2 if $k + 1 < @T && $T[$k][0] eq 'LP' && $T[$k + 1][0] eq 'RP';
    }
    if (defined $name) {
      $k++ while $k < @T && $T[$k][0] eq 'NL';
      if ($k >= @T || $T[$k][0] ne 'LB') {
        fail("$SCRIPT:$t->[2]: function $name: body is not a { ... } block") if $name =~ /^_cursor_agent/;
        $j++;
        next;
      }
      my ($d, $s) = (0, $k);
      for (; $k < @T; $k++) {
        $d++ if $T[$k][0] eq 'LB';
        if ($T[$k][0] eq 'RB') { $d--; last if $d == 0 }
      }
      fail("$SCRIPT:$t->[2]: function $name: unterminated body") if $k >= @T;
      fail("$SCRIPT:$t->[2]: function $name is defined twice (first at line $FN{$name}{line})") if $FN{$name};
      $FN{$name} = { line => $t->[2], body => [@T[$s + 1 .. $k - 1]] };
      push @FNORDER, $name;
      $j = $k + 1;
      next;
    }
    if ($t->[0] eq 'W' && wtext($t->[1]) =~ /^(_arguments|_describe)$/) {
      fail("$SCRIPT:$t->[2]: $1 at file scope (outside any function)");
    }
    $j++;
  }
}
fail("$SCRIPT: no _cursor_agent function found; is this the completion script?") unless $FN{_cursor_agent};

my %ARR;        # fn -> name -> [word tokens]
my %ARRDEF;     # name -> fn -> 1
my @CMDS;       # { fn, words => [W tokens], line, arm }
my %ARMS;       # fn -> [ { pats => [], calls => [], line } ]

sub dispatch_subject { $_[0] =~ /^\$\{?(?:words|line)\[/ }

my %KEYWORD = map { $_ => 1 } qw(if then else elif fi do done while until for in ! time noglob builtin command exec local typeset declare integer readonly);

for my $fn (@FNORDER) {
  my @b = @{$FN{$fn}{body}};
  my @stack;      # { subj, disp, state => pat|body, pats => [], arm }
  my @cmd;
  my $cmdline;
  my $finish = sub {
    return unless @cmd;
    my @w = @cmd;
    @cmd = ();
    shift @w while @w && ($KEYWORD{wtext($w[0][1])} || wtext($w[0][1]) =~ /^\w+=/);
    return unless @w;
    my $name = wtext($w[0][1]);
    my ($arm) = map { $_->{arm} } grep { $_->{disp} && $_->{state} eq 'body' } reverse @stack;
    $arm = $arm->[0] if ref $arm eq 'ARRAY';
    if ($name eq '_arguments' || $name eq '_describe' || $name eq '_cursor_agent_describe_groups') {
      if ($arm && !grep { $_ eq '*' } @{$arm->{pats}}) {
        fail("$SCRIPT:$w[0][2]: $name inside dispatch arm '" . join('|', @{$arm->{pats}}) . ")' of $fn; "
          . "move it into that subcommand's own function");
      }
      push @CMDS, { fn => $fn, words => \@w, line => $w[0][2], arm => $arm };
    } elsif ($name =~ /^_cursor_agent\w*$/) {
      push @{$arm->{calls}}, $name if $arm;
    }
  };
  for (my $j = 0; $j < @b; $j++) {
    my $t = $b[$j];
    my $top = $stack[-1];
    if ($top && $top->{state} eq 'pat') {
      next if $t->[0] eq 'NL';
      if ($t->[0] eq 'W' && wtext($t->[1]) eq 'esac' && !@{$top->{pats}}) { pop @stack; next }
      next if $t->[0] eq 'LP' && !@{$top->{pats}};
      next if $t->[0] eq 'PIPE';
      if ($t->[0] eq 'W') { push @{$top->{pats}}, wtext($t->[1]); next }
      if ($t->[0] eq 'RP') {
        fail("$SCRIPT:$t->[2]: empty case pattern in $fn") unless @{$top->{pats}};
        my $arm = { pats => $top->{pats}, calls => [], line => $t->[2] };
        push @{$ARMS{$fn}}, $arm if $top->{disp};
        $top->{arm} = [$arm];
        $top->{pats} = [];
        $top->{state} = 'body';
        next;
      }
      fail("$SCRIPT:$t->[2]: unexpected '$t->[0]' in a case pattern in $fn");
    }
    if ($t->[0] eq 'ASSIGN') {
      my ($an, $plus) = @{$t->[1]};
      my @el;
      $j++;
      for (; $j < @b; $j++) {
        last if $b[$j][0] eq 'RP';
        next if $b[$j][0] eq 'NL';
        fail("$SCRIPT:$b[$j][2]: unexpected '$b[$j][0]' in array $an in $fn") unless $b[$j][0] eq 'W';
        push @el, $b[$j];
      }
      fail("$SCRIPT:$t->[2]: unterminated array $an in $fn") if $j >= @b;
      if ($plus) { push @{$ARR{$fn}{$an}}, @el } else { $ARR{$fn}{$an} = \@el }
      $ARRDEF{$an}{$fn} = 1;
      next;
    }
    if ($t->[0] eq 'W') {
      my $w = wtext($t->[1]);
      if (!@cmd && $w eq 'case') {
        my $s = $b[$j + 1];
        my $in = $b[$j + 2];
        fail("$SCRIPT:$t->[2]: malformed case statement in $fn")
          unless $s && $s->[0] eq 'W' && $in && $in->[0] eq 'W' && wtext($in->[1]) eq 'in';
        push @stack, { subj => wtext($s->[1]), disp => (dispatch_subject(wtext($s->[1])) ? 1 : 0), state => 'pat', pats => [] };
        $j += 2;
        next;
      }
      if (!@cmd && $w eq 'esac' && $top) { pop @stack; next }
      push @cmd, $t;
      next;
    }
    $finish->();
    if ($t->[0] eq 'SEMI2') {
      fail("$SCRIPT:$t->[2]: ';;' outside a case statement in $fn") unless $top;
      $top->{state} = 'pat';
      $top->{arm} = undef;
    }
  }
  $finish->();
  fail("$SCRIPT:$FN{$fn}{line}: unterminated case statement in $fn") if @stack;
}

# --- word expansion -----------------------------------------------------------

# Array named $n as seen from $fn (own definition first, then the single
# function that defines it, as zsh's dynamic scoping would find it).
sub array_of {
  my ($fn, $n, $line) = @_;
  return $ARR{$fn}{$n} if $ARR{$fn} && $ARR{$fn}{$n};
  my @d = keys %{$ARRDEF{$n} || {}};
  fail("$SCRIPT:$line: $fn references array '$n', which no function defines") unless @d;
  fail("$SCRIPT:$line: $fn references array '$n', defined in several functions (@d); cannot tell which is in scope") if @d > 1;
  return $ARR{$d[0]}{$n};
}

# Brace-expand one word: a list of strings (quoted text never expands).
sub expand_word {
  my ($seg, $line) = @_;
  my @out = ('');
  for my $s (@$seg) {
    if ($s->[2]) {
      fail("$SCRIPT:$line: cannot evaluate parameter expansion in " . wraw($seg));
    }
    my @alts;
    if ($s->[0] ne 'b') {
      @alts = ([$s->[1]]);
    } else {
      my $t = $s->[1];
      while ($t =~ /\G(.*?)\{([^{}]*)\}/gcs) {
        my ($pre, $in) = ($1, $2);
        push @alts, [$pre] if length $pre;
        if ($in =~ /,/) { push @alts, [split /,/, $in, -1] }
        else { push @alts, ["{$in}"] }
      }
      my $rest = substr($t, pos($t) // 0);
      push @alts, [$rest] if length $rest;
    }
    for my $a (@alts) {
      @out = map { my $o = $_; map { $o . $_ } @$a } @out;
    }
  }
  return @out;
}

# Expand the words of a command into [string, group-id, line] items, splicing
# referenced arrays. Specs from one word (one brace pair) share a group id.
sub expand_args {
  my ($fn, $words) = @_;
  my @items;
  my $wi = 0;
  for my $w (@$words) {
    $wi++;
    my $seg = $w->[1];
    my $txt = join '', map { $_->[1] } @$seg;
    if (@$seg == 1 && $seg->[0][0] ne 'q' && $txt =~ /^\$\{?(?:\(@\))?([A-Za-z_]\w*)(?:\[@\])?\}?$/) {
      my $n = $1;
      my $arr = array_of($fn, $n, $w->[2]);
      my $ei = 0;
      for my $e (@$arr) {
        $ei++;
        push @items, [$_, "a:$n:$ei", $e->[2]] for expand_word($e->[1], $e->[2]);
      }
      next;
    }
    push @items, [$_, "w:$w->[2]:$wi", $w->[2]] for expand_word($seg, $w->[2]);
  }
  return @items;
}

# Split a value spec (`msg:action`) and read enum values from the action.
sub split_unescaped_colon {
  my $s = shift;
  return ($1, $2) if $s =~ /^((?:[^:\\]|\\.)*):(.*)$/s;
  return ($s, '');
}

sub action_choices {
  my $a = shift;
  if ($a =~ /^\s*\(\((.*)\)\)\s*$/s) {
    my @v = map { (split /(?<!\\)\\?:/, $_, 2)[0] } grep { length } split /(?<!\\)\s+/, $1;
    return [@v];
  }
  if ($a =~ /^\s*\((.*)\)\s*$/s) {
    my @v = grep { length } split /\s+/, $1;
    return @v ? [@v] : undef;
  }
  return undef;
}

# ===========================================================================
# Script model per function
# ===========================================================================

my %SOPT;       # fn -> flag -> { value, choices, rep, gid, line }
my %SGROUP;     # fn -> gid -> [flags]
my %SEXCL;      # fn -> [ [flag, line] ]
my %SPOS;       # fn -> slot -> { choices, line }
my %SROSTER;    # fn -> [ [name, tag, line] ]
my @FIND;       # { fn, path, code, entry, detail }
my %SEEN;       # de-duplication of exclusion entries

my %F2P;        # function -> path
$F2P{fname($_)} = $_ for keys %PATH;

sub finding {
  my ($fn, $code, $entry, $detail) = @_;
  my $p = $F2P{$fn};
  if (!defined $p) {
    ($p) = grep { fname($_) eq $fn } keys %DEVPATH;
    if (!defined $p) {
      (my $b = $fn) =~ s/_commands$//;
      $p = $F2P{$b} ? "$F2P{$b}, roster" : '(no command path)';
    }
  }
  push @FIND, { fn => $fn, path => $p, code => $code, entry => $entry, detail => $detail };
}

sub show_choices { defined $_[0] ? '(' . join(' ', @{$_[0]}) . ')' : 'none' }
sub same_choices {
  my ($x, $y) = @_;
  return !defined $x && !defined $y if !defined $x || !defined $y;
  return join("\0", sort @$x) eq join("\0", sort @$y);
}

for my $c (@CMDS) {
  my $fn = $c->{fn};
  my @w = @{$c->{words}};
  my $name = wtext((shift @w)->[1]);
  my @items = expand_args($fn, \@w);
  if ($name eq '_cursor_agent_describe_groups') {
    fail("$SCRIPT:$c->{line}: _cursor_agent_describe_groups in $fn: expected <tag> <description> <array> triples")
      unless @items && @items % 3 == 0;
    while (my ($tg, $ds, $an) = splice(@items, 0, 3)) {
      fail("$SCRIPT:$c->{line}: _cursor_agent_describe_groups in $fn: expected an array name, got '$an->[0]'")
        unless $an->[0] =~ /^[A-Za-z_]\w*$/;
      for my $e (@{array_of($fn, $an->[0], $an->[2])}) {
        for my $s (expand_word($e->[1], $e->[2])) {
          my ($n) = split_unescaped_colon($s);
          $n =~ s/\\(.)/$1/g;
          push @{$SROSTER{$fn}}, [$n, $tg->[0], $e->[2]];
        }
      }
    }
    next;
  }
  if ($name eq '_describe') {
    my ($tag, $descr, @arrs) = ('');
    while (@items) {
      my $x = shift @items;
      my $s = $x->[0];
      if (!defined $descr) {
        if ($s eq '-t') { $tag = (shift @items // [''])->[0]; next }
        if ($s =~ /^-[JV]$/) { shift @items; next }
        if ($s =~ /^-[12xoO]+$/) { next }
        $descr = $s;
        next;
      }
      if ($s =~ /^[A-Za-z_]\w*$/) { push @arrs, [$s, $x->[2]]; last }
      fail("$SCRIPT:$c->{line}: _describe in $fn: expected an array name after the description, got '$s'");
    }
    fail("$SCRIPT:$c->{line}: _describe in $fn names no array") unless @arrs;
    for my $an (@arrs) {
      for my $e (@{array_of($fn, $an->[0], $an->[1])}) {
        for my $s (expand_word($e->[1], $e->[2])) {
          my ($n) = split_unescaped_colon($s);
          $n =~ s/\\(.)/$1/g;
          push @{$SROSTER{$fn}}, [$n, $tag eq '' ? '(no -t tag)' : $tag, $e->[2]];
        }
      }
    }
    next;
  }
  # _arguments: leading flags, then specs.
  while (@items) {
    my $s = $items[0][0];
    if ($s =~ /^-[AMO]$/) { shift @items; shift @items; next }
    if ($s =~ /^-[nswWCRS0]+$/) { shift @items; next }
    last;
  }
  my $next = 0;
  for my $x (@items) {
    my ($s, $gid, $line) = @$x;
    fail("$SCRIPT:$line: _arguments in $fn: '--' (help parsing) is not supported") if $s eq '--';
    my $orig = $s;
    my $excl = '';
    if ($s =~ s/^\(((?:[^)\\]|\\.)*)\)//s) { $excl = $1 }
    for my $e (split ' ', $excl) {
      push @{$SEXCL{$fn}}, [$e, $line] if $e =~ /^[-+]./ && !$SEEN{"$fn\0$e\0$line"}++;
    }
    if ($s =~ /^\*(:{1,3})(.*)$/s) {
      my (undef, $act) = split_unescaped_colon($2);
      next if $act =~ /^\s*->/;
      $SPOS{$fn}{'*'} //= { choices => action_choices($act), line => $line };
      next;
    }
    if ($s =~ /^(\d*)(::?)(.*)$/s) {
      my $pos = length $1 ? $1 : $next + 1;
      $next = $pos if $pos > $next;
      my (undef, $act) = split_unescaped_colon($3);
      next if $act =~ /^\s*->/;
      next if $pos == 1 && $act =~ /^\s*(\S+)\s*$/ && $1 eq "${fn}_commands";
      $SPOS{$fn}{$pos} //= { choices => action_choices($act), line => $line };
      next;
    }
    my $rep = ($s =~ s/^\*(?=[-+])//) ? 1 : 0;
    if ($s =~ /^([-+]{1,2}[^\[:=+]*?)(?:=-|=|\+|-)?(?:\[(?:[^\]\\]|\\.)*\])?(:.*)?$/s) {
      my ($flag, $rest) = ($1, $2);
      my ($value, $choices) = ('none', undef);
      if (defined $rest) {
        my $r;
        if ($rest =~ /^::(.*)$/s) { $value = 'optional'; $r = $1 }
        else { $value = 'required'; $r = substr($rest, 1) }
        my (undef, $act) = split_unescaped_colon($r);
        $choices = action_choices($act);
      }
      my $o = { value => $value, choices => $choices, rep => $rep, gid => $gid, line => $line };
      if (my $prev = $SOPT{$fn}{$flag}) {
        next if $prev->{gid} eq $gid;
        if ($prev->{value} ne $value || $prev->{rep} != $rep || !same_choices($prev->{choices}, $choices)) {
          finding($fn, 'opt-conflict', $flag, "specified at lines $prev->{line} and $line with different value, repeat or enum");
        }
        push @{$SGROUP{$fn}{$gid}}, $flag     # still one spec word, for the alias checks
          unless grep { $_ eq $flag } @{$SGROUP{$fn}{$gid} || []};
        next;
      }
      $SOPT{$fn}{$flag} = $o;
      push @{$SGROUP{$fn}{$gid}}, $flag;
      next;
    }
    fail("$SCRIPT:$line: _arguments spec in $fn not understood: $orig");
  }
}

# ===========================================================================
# Compare
# ===========================================================================

sub long_of { (sort { length $b <=> length $a || $a cmp $b } @_)[0] }

sub expected_tag {
  my ($p, $c) = @_;
  return 'hidden-commands' if $c->{hidden};
  return 'gated-commands' if $c->{tier} =~ /^gated:/;
  return 'commands';
}

my %ROOTFLAGS = map { my $o = $_; map { $_ => $o } @{$o->{flags}} } @{$OPT{agent} || []};

for my $p (sort keys %PATH) {
  my $fn = fname($p);
  unless ($FN{$fn}) {
    my $no = scalar @{$OPT{$p} || []};
    my $na = scalar keys %{$ARG{$p} || {}};
    my $nc = scalar keys %{$CHILD{$p} || {}};
    finding($fn, 'function-missing', $fn, "not defined; the snapshot has $no options, $na positionals, $nc subcommands for '$p'");
    next;
  }

  # --- options ---
  my $so = $SOPT{$fn} || {};
  my %claimed;
  for my $o (@{$OPT{$p} || []}) {
    my @fl = @{$o->{flags}};
    my $long = long_of(@fl);
    my @have = grep { $so->{$_} } @fl;
    $claimed{$_} = 1 for @fl;
    unless (@have) {
      my $d = "`$o->{spec}` (value=$o->{value}" . ($o->{rep} ? ', repeatable' : '')
        . (defined $o->{choices} ? ', choices=' . join(',', @{$o->{choices}}) : '') . ", $o->{tier})";
      finding($fn, 'opt-missing', $long, $d);
      next;
    }
    my @lack = grep { !$so->{$_} } @fl;
    my %g = map { $so->{$_}{gid} => 1 } @have;
    if (@lack) {
      finding($fn, 'opt-alias', $long, "lacks " . join(', ', @lack) . " (snapshot: `$o->{spec}`)");
    } elsif (@fl > 1 && keys %g > 1) {
      finding($fn, 'opt-alias', $long, "written as separate specs; the snapshot pairs them (`$o->{spec}`): write {" . join(',', @fl) . "}");
    }
    my $s = $so->{$have[0]};
    if ($s->{value} ne $o->{value}) {
      my %how = (none => 'boolean', required => "required value (':')", optional => "optional value ('::')");
      finding($fn, 'opt-value', $long, "script: $how{$s->{value}}, snapshot: $how{$o->{value}} (line $s->{line})");
    }
    if ($s->{rep} != $o->{rep}) {
      finding($fn, 'opt-repeat', $long, $o->{rep}
        ? "repeatable in the snapshot; prefix the spec with '*' (line $s->{line})"
        : "not repeatable in the snapshot; drop the '*' prefix (line $s->{line})");
    }
    my $want = $o->{choices};
    for my $f (@fl) { $want //= $ENUM{$p}{$f} }
    my $got = $s->{choices};
    if (defined $want && !defined $got) {
      finding($fn, 'enum-missing', $long, "complete " . show_choices($want) . " (line $s->{line})");
    } elsif (!defined $want && defined $got) {
      finding($fn, 'enum-extra', $long, "script completes " . show_choices($got) . "; the snapshot records no choices (line $s->{line})");
    } elsif (defined $want && !same_choices($want, $got)) {
      my %w = map { $_ => 1 } @$want;
      my %h = map { $_ => 1 } @$got;
      my @m = grep { !$h{$_} } @$want;
      my @x = grep { !$w{$_} } @$got;
      finding($fn, 'enum-values', $long, join('; ', (@m ? 'missing ' . join(' ', @m) : ()), (@x ? 'extra ' . join(' ', @x) : ()))
        . " (line $s->{line})");
    }
  }
  # Root options granted by a `[options]` usage: presence only. When none is
  # present, one finding stands for all of them.
  if ($INHERIT{$p}) {
    my (@lack, $n);
    for my $o (@{$OPT{agent} || []}) {
      my @fl = @{$o->{flags}};
      next if grep { $claimed{$_} } @fl;
      $claimed{$_} = 1 for @fl;
      $n++;
      push @lack, $o unless grep { $so->{$_} } @fl;
    }
    if ($n && @lack == $n) {
      finding($fn, 'opt-missing', '[options]', "none of the $n root options that `$INHERIT{$p}` accepts (reuse the root's global_options array)");
    } else {
      finding($fn, 'opt-missing', long_of(@{$_->{flags}}), "root option `$_->{spec}`, which `$INHERIT{$p}` accepts") for @lack;
    }
  }
  # Script groups (one brace pair or one spec) the snapshot does not have.
  my %dev = (%{$DEVOPT{$p} || {}}, ($INHERIT{$p} ? %{$DEVOPT{agent} || {}} : ()));
  for my $gid (sort { $so->{$SGROUP{$fn}{$a}[0]}{line} <=> $so->{$SGROUP{$fn}{$b}[0]}{line} || $a cmp $b } keys %{$SGROUP{$fn} || {}}) {
    my @fl = @{$SGROUP{$fn}{$gid}};
    my $line = $so->{$fl[0]}{line};
    my @extra = grep { !$claimed{$_} } @fl;
    for my $f (grep { $dev{$_} } @extra) {
      finding($fn, 'dev-only', $f, "option is tier 4 (dev-only, compiled out); remove it (line $line)");
    }
    @extra = grep { !$dev{$_} } @extra;
    if (@extra) {
      finding($fn, 'opt-extra', long_of(@extra), join(', ', @extra) . " not in the snapshot for '$p' (line $line)");
    }
    if (@fl > 1 && @extra < @fl) {
      my %rec;
      for my $o (@{$OPT{$p} || []}, ($INHERIT{$p} ? @{$OPT{agent} || []} : ())) {
        for my $f (@{$o->{flags}}) { $rec{$f} //= $o }
      }
      my %which = map { ($rec{$_} // 0) . '' => 1 } grep { $claimed{$_} } @fl;
      if (keys %which > 1) {
        finding($fn, 'opt-alias', long_of(@fl), "brace pair {" . join(',', @fl) . "} joins options the snapshot keeps separate (line $line)");
      }
    }
  }
  for my $e (@{$SEXCL{$fn} || []}) {
    finding($fn, 'excl-unknown', $e->[0], "exclusion group names a flag this function does not specify (line $e->[1])")
      unless $so->{$e->[0]};
  }

  # --- positionals ---
  my $sp = $SPOS{$fn} || {};
  my $ap = $ARG{$p} || {};
  for my $slot (sort keys %$ap) {
    my $a = $ap->{$slot};
    my $s = $sp->{$slot};
    unless ($s) {
      finding($fn, 'arg-missing', "arg$slot", "`$a->{name}`: add a '" . ($slot eq '*' ? '*' : $slot) . ":...' spec");
      next;
    }
    (my $an = $a->{name}) =~ s/\.\.\.(?=[>\]])//;
    my $want = $ENUM{$p}{$a->{name}} // $ENUM{$p}{$an};
    my $got = $s->{choices};
    if (defined $want && !defined $got) {
      finding($fn, 'enum-missing', "arg$slot", "`$a->{name}`: complete " . show_choices($want) . " (line $s->{line})");
    } elsif (!defined $want && defined $got) {
      finding($fn, 'enum-extra', "arg$slot", "`$a->{name}`: script completes " . show_choices($got) . "; the snapshot records no values (line $s->{line})");
    } elsif (defined $want && !same_choices($want, $got)) {
      finding($fn, 'enum-values', "arg$slot", "`$a->{name}`: script " . show_choices($got) . ", snapshot " . show_choices($want) . " (line $s->{line})");
    }
  }
  for my $slot (sort keys %$sp) {
    next if $ap->{$slot};
    finding($fn, 'arg-extra', "arg$slot", "positional '$slot:' has no `arg` record for '$p' (line $sp->{$slot}{line})");
  }

  # --- subcommands: rosters and dispatch ---
  my $kids = $CHILD{$p} || {};
  my %want;     # word -> [child name, tag]
  for my $k (keys %$kids) {
    my $tag = expected_tag($p, $kids->{$k});
    $want{$k} = [$k, $tag];
    $want{$_} = [$k, $tag] for @{$kids->{$k}{aliases}};
  }
  my %got;      # word -> [ [tag, line] ]
  my %seen;     # one array entry offered by several roster calls counts once
  for my $src ($fn, "${fn}_commands") {
    push @{$got{$_->[0]}}, [$_->[1], $_->[2]]
      for grep { !$seen{"$_->[0]\0$_->[1]\0$_->[2]"}++ } @{$SROSTER{$src} || []};
  }
  my %devk = %{$DEVCHILD{$p} || {}};
  for my $w (sort keys %want) {
    my ($k, $tag) = @{$want{$w}};
    my $what = $w eq $k ? '' : " (alias of $k)";
    my $g = $got{$w};
    if (!$g) {
      finding($fn, 'cmd-missing', $w, "roster entry absent$what; expected in tag $tag");
    } else {
      if (@$g > 1) {
        finding($fn, 'cmd-dup', $w, "listed " . scalar(@$g) . " times (lines " . join(', ', map { $_->[1] } @$g) . ")");
      }
      for my $e (grep { $_->[0] ne $tag } @$g) {
        finding($fn, 'cmd-tag', $w, "in tag $e->[0], expected $tag$what (line $e->[1])");
      }
    }
  }
  for my $w (sort keys %got) {
    next if $want{$w};
    my $l = $got{$w}[0][1];
    if ($devk{$w}) { finding($fn, 'dev-only', $w, "roster entry for a tier 4 (dev-only) command; remove it (line $l)") }
    else { finding($fn, 'cmd-extra', $w, "roster entry not in the snapshot for '$p' (line $l)") }
  }
  my %arm;      # word -> arm
  for my $a (@{$ARMS{$fn} || []}) {
    for my $pat (@{$a->{pats}}) { $arm{$pat} //= $a unless $pat eq '*' }
  }
  for my $w (sort keys %want) {
    my $k = $want{$w}[0];
    my $target = fname("$p $k");
    my $a = $arm{$w};
    if (!$a) {
      finding($fn, 'dispatch-missing', $w, "no '$w)' arm calling $target in the case \$words[1] dispatch");
    } elsif (!grep { $_ eq $target } @{$a->{calls}}) {
      my $c = @{$a->{calls}} ? join(', ', @{$a->{calls}}) : 'no _cursor_agent function';
      finding($fn, 'dispatch-target', $w, "arm calls $c; expected $target (line $a->{line})");
    }
  }
  for my $w (sort keys %arm) {
    next if $want{$w};
    if ($devk{$w}) { finding($fn, 'dev-only', $w, "dispatch arm for a tier 4 (dev-only) command; remove it (line $arm{$w}{line})") }
    else { finding($fn, 'dispatch-extra', $w, "arm for a word that is not a subcommand of '$p' (line $arm{$w}{line})") }
  }
}

# Functions that map to no path (or to a dev-only path).
for my $fn (@FNORDER) {
  next unless $fn =~ /^_cursor_agent/;
  next if $F2P{$fn};
  (my $b = $fn) =~ s/_commands$//;
  next if $b ne $fn && $F2P{$b} && ($CHILD{$F2P{$b}} || $SROSTER{$fn});
  my ($dp) = grep { fname($_) eq $fn } sort keys %DEVPATH;
  if ($dp) { finding($fn, 'dev-only', $fn, "function for tier 4 (dev-only) command '$dp'; remove it (line $FN{$fn}{line})") }
  else { finding($fn, 'function-extra', $fn, "no command path in the snapshot maps to this function (line $FN{$fn}{line})") }
}

# Header target version.
if ($VERSION ne '') {
  my ($hv) = $SRC =~ /^# Target: Cursor CLI (\S+)\s*$/m;
  if (!defined $hv) {
    finding('_cursor_agent', 'target-version', 'target-version', "no '# Target: Cursor CLI <version>' header line; the snapshot is $VERSION");
  } elsif ($hv ne $VERSION) {
    finding('_cursor_agent', 'target-version', 'target-version', "header says $hv, the snapshot is $VERSION");
  }
}

# ===========================================================================
# Exceptions and report
# ===========================================================================

my @EXC;        # [line, fn, code, entry, used]
if ($EXC ne '' && -e $EXC) {
  my $ln = 0;
  for my $l (split /\n/, slurp($EXC)) {
    $ln++;
    next if $l =~ /^\s*(#|$)/;
    my @f = map { s/^\s+|\s+$//gr } split /\|/, $l, 4;
    fail("$EXC:$ln: expected '<function> | <code> | <entry> | <reason>': $l")
      unless @f == 4 && $f[0] =~ /^_cursor_agent\w*$/ && $f[1] =~ /^[a-z-]+$/ && length $f[2] && length $f[3];
    push @EXC, [$ln, @f[0 .. 2], 0];
  }
}
my $excepted = 0;
my @left;
for my $f (@FIND) {
  my @m = grep { $_->[1] eq $f->{fn} && $_->[2] eq $f->{code} && $_->[3] eq $f->{entry} } @EXC;
  if (@m) { $_->[4]++ for @m; $excepted++; next }
  push @left, $f;
}
my $ename = $EXC eq '' ? '' : ($EXC =~ s{.*/}{}r);
my @stale = map { "$ename:$_->[0] (exceptions): exception-unused $_->[1] | $_->[2] | $_->[3]: matches no finding; delete the line" }
  grep { !$_->[4] } @EXC;

# Group by function, in path order (root first), unmapped functions last.
my %order;
{
  my $i = 0;
  $order{fname($_)} = $i++ for sort { ($a eq 'agent' ? '' : $a) cmp ($b eq 'agent' ? '' : $b) } keys %PATH;
}
my %by;
push @{$by{$_->{fn}}}, $_ for @left;
my @fns = sort { ($order{$a} // 1e9) <=> ($order{$b} // 1e9) || $a cmp $b } keys %by;
my %corank = map { $_ => 0 } qw(function-missing function-extra);
unless ($QUIET) {
  my $first = 1;
  for my $fn (@fns) {
    print "\n" unless $first;
    $first = 0;
    for my $f (sort { ($corank{$a->{code}} // 1) <=> ($corank{$b->{code}} // 1) || $a->{code} cmp $b->{code} || $a->{entry} cmp $b->{entry} } @{$by{$fn}}) {
      print "$f->{fn} ($f->{path}): $f->{code} $f->{entry}: $f->{detail}\n";
    }
  }
  if (@stale) {
    print "\n" unless $first;
    print "$_\n" for @stale;
  }
  print "\n" if @left || @stale;
}
my $sname = $SCRIPT =~ s{.*/}{}r;
my $pname = $SNAP =~ s{.*/}{}r;
my $ver = $VERSION eq '' ? '' : " ($VERSION)";
if (!@left && !@stale) {
  print "check-coverage: OK: $sname covers $pname$ver in both directions"
    . " (" . scalar(keys %PATH) . " command paths, $excepted findings excepted)\n";
  exit 0;
}
print "check-coverage: GAPS: " . scalar(@left) . " findings in " . scalar(@fns) . " functions"
  . (@stale ? ", " . scalar(@stale) . " stale exceptions" : '')
  . " ($excepted excepted; $sname against $pname$ver)\n";
print "  Edit the functions named above in src/_cursor-agent and regenerate their test cases,\n"
  . "  or record a deliberate deviation in tools/coverage-exceptions.txt.\n" unless $QUIET;
exit 1;
PERL
}

# The header's usage, options, exit codes and report paragraphs.
usage() {
  local line on=0
  while IFS= read -r line; do
    [[ $line == '# Usage:' ]] && on=1
    [[ $line == 'emulate -L zsh' ]] && break
    (( on )) || continue
    line=${line#\#}
    print -r -- "${line# }"
  done <"$SCRIPT_PATH"
}

usage_error() {
  print -ru2 -- "check-coverage: $*"
  print -ru2 -- "Run 'zsh tools/check-coverage.zsh --help' for usage."
  exit 2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local exc_set=0
  while (( $# )); do
    case $1 in
      --script|--snapshot|--exceptions)
        (( $# >= 2 )) || usage_error "$1 needs a file"
        case $1 in
          --script)     SCRIPT_FILE=$2 ;;
          --snapshot)   SNAPSHOT=$2 ;;
          --exceptions) EXCEPTIONS=$2; exc_set=1 ;;
        esac
        shift 2
        ;;
      --script=*)     SCRIPT_FILE=${1#*=}; shift ;;
      --snapshot=*)   SNAPSHOT=${1#*=}; shift ;;
      --exceptions=*) EXCEPTIONS=${1#*=}; exc_set=1; shift ;;
      -q|--quiet)     QUIET=1; shift ;;
      -h|--help|help) usage; return 0 ;;
      -*)             usage_error "unknown option '$1'" ;;
      *)              usage_error "unexpected argument '$1'" ;;
    esac
  done
  command -v perl >/dev/null 2>&1 || die "perl not found; the checker needs it"
  [[ -r $SCRIPT_FILE ]] || die "cannot read script $SCRIPT_FILE"
  [[ -r $SNAPSHOT ]] || die "cannot read snapshot $SNAPSHOT"
  if [[ ! -e $EXCEPTIONS ]]; then
    (( exc_set )) && die "no exceptions file at $EXCEPTIONS"
    EXCEPTIONS=''
  fi
  # The program arrives on stdin (`perl -`): no temp file, no argument-size limit.
  write_checker | perl - "$SCRIPT_FILE" "$SNAPSHOT" "$EXCEPTIONS" "$QUIET"
}

main "$@"
