#!/bin/sh
# platform: macOS-only -- runs the product's python, which is a macOS build
#   usage: [REGRTEST_CONTEXT=stage|installed] tests/regrtest.sh <python> <known-failures-file>
#          Runs CPython's regression suite with <python>, by its physical path, with every resource but
#          network, gui, audio and largefile (largefile writes multi-GB files). It passes only when the
#          tests that fail are exactly the ones <known-failures-file> lists, one per line:
#            <test id>  # <reason>                            fails
#            stage: <test id>  # <reason>                     fails only when REGRTEST_CONTEXT is stage
#            flaky: <test id>  # <reason>                     may fail or pass
#            ignore: <test id>  # <reason>. Revisit when <exit>.   not run (regrtest --ignore)
#          A test id is a unittest id without its leading `test.` (test_math.FMATests.test_fma_zero_result),
#          or a test file's name, which stands for whatever the file did besides failing tests: a crash,
#          a timeout, a worker that exited non-zero.
#          REGRTEST_CONTEXT defaults to installed when <python>'s prefix is its configured prefix (the
#          parent of sysconfig's LIBDIR; sysconfig's own `prefix` follows sys.prefix), else stage. A stage run refuses a host where the configured prefix exists: a stage's copied venv
#          interpreters would load that installed libpython through python3.15's fallback rpath.
#          Exits 77 when given no arguments.
set -eu
fail() { echo "FAIL: $*"; exit 1; }
if [ $# -eq 0 ]; then
  echo "SKIP: usage: tests/regrtest.sh <python> <known-failures-file>"; exit 77
fi
[ $# -eq 2 ] || { echo "usage: tests/regrtest.sh <python> <known-failures-file>" >&2; exit 2; }
pydir="$(cd -P "$(dirname "$1")" && pwd -P)" || fail "no directory $(dirname "$1")"
py="$pydir/$(basename "$1")"
case "$2" in /*) known="$2" ;; *) known="$PWD/$2" ;; esac
[ -x "$py" ] || fail "$py is not executable"
prefixes="$("$py" -I -c 'import os, sys, sysconfig
print(os.path.realpath(sys.prefix))
print(os.path.dirname(sysconfig.get_config_var("LIBDIR")))')" || fail "$py could not report its prefix"
real_prefix="$(printf '%s\n' "$prefixes" | sed -n 1p)"
config_prefix="$(printf '%s\n' "$prefixes" | sed -n 2p)"
[ -n "$real_prefix" ] && [ -n "$config_prefix" ] || fail "$py reported no prefix: $prefixes"
installed_prefix=""
[ ! -d "$config_prefix" ] || installed_prefix="$(cd -P "$config_prefix" && pwd -P)"
case "${REGRTEST_CONTEXT:-}" in
  "") if [ "$real_prefix" = "$installed_prefix" ]; then context=installed; else context=stage; fi ;;
  stage | installed) context="$REGRTEST_CONTEXT" ;;
  *) echo "REGRTEST_CONTEXT is $REGRTEST_CONTEXT, not stage or installed" >&2; exit 2 ;;
esac
if [ "$context" = stage ] && [ -n "$installed_prefix" ] && [ "$real_prefix" != "$installed_prefix" ]; then
  fail "a stage run on a host where $config_prefix is installed tests that installed libpython in its copied venvs; run it on a host without $config_prefix, or against the installed tree"
fi
[ -r "$known" ] || fail "cannot read $known"
t="$(mktemp -d "${TMPDIR:-/tmp}/regrtest.XXXXXX")"
trap 'rm -rf "$t"' EXIT

: > "$t/listed"; : > "$t/flaky"; : > "$t/ignore"
awk -v ctx="$context" -v d="$t" '
  /^[ \t]*$/ || /^#/ { next }
  { kind = "fails"; line = $0 }
  match(line, /^(stage|flaky|ignore):[ \t]+/) { kind = substr(line, 1, index(line, ":") - 1); line = substr(line, RLENGTH + 1) }
  line !~ /^[A-Za-z0-9_.]+[ \t]+#[ \t]*[^ \t]/ {
    printf "line %d is not `[stage:|flaky:|ignore:] <test id>  # <reason>`: %s\n", NR, $0; bad = 1; next }
  { split(line, w, /[ \t]+/); id = w[1] }
  kind == "ignore" && line !~ /Revisit when [^ \t]/ {
    printf "line %d ignores %s without saying when to revisit it (`# <reason>. Revisit when <exit>.`)\n", NR, id; bad = 1; next }
  seen[id]++ { printf "line %d lists %s again\n", NR, id; bad = 1; next }
  kind == "fails" || (kind == "stage" && ctx == "stage") { print id > (d "/listed"); next }
  kind == "flaky" || kind == "ignore" { print id > (d "/" kind) }
  END { exit bad }' "$known" > "$t/known-errors" || fail "$known: $(cat "$t/known-errors")"
for f in listed flaky ignore; do LC_ALL=C sort -o "$t/$f" "$t/$f"; done
set --
while read -r id; do set -- "$@" --ignore "test.$id"; done < "$t/ignore"

cd "$t"
{ rc=0; "$py" -m test -j0 -W --timeout 600 -uall,-network,-gui,-audio,-largefile "$@" || rc=$?; echo "$rc" > "$t/rc"; } 2>&1 | tee "$t/log"
[ -s "$t/rc" ] || fail "the suite exited without reporting a status"
rc="$(cat "$t/rc")"

awk '
  BEGIN { esc = sprintf("%c", 27) }
  { gsub(esc "\\[[0-9;]*m", ""); sub(/\r$/, "") }
  function bare(id) { sub(/^test\./, "", id); return id }
  /^[0-9]+:[0-9][0-9]:[0-9][0-9] .*\[ *[0-9]+\/[0-9]+(\/[0-9]+)?\] / {
    s = substr($0, index($0, "] ") + 2); split(s, w, " "); cur = w[1]
    if (substr(s, length(cur) + 2) ~ /^failed( \([0-9]+ (errors?|failures?)(, [0-9]+ failures?)?\))?( \([0-9][^)]*\)| --|$)/) plain[cur] = 1
    next
  }
  /^(FAIL|ERROR|UNEXPECTED SUCCESS): / {
    p = index($0, " ("); if (p == 0 || cur == "") next
    s = substr($0, p + 2); q = index(s, ")"); if (q == 0) next
    named[cur] = named[cur] " " bare(substr(s, 1, q - 1)); next
  }
  /^[0-9]+ tests? failed:$/ { inblock = 1; next }
  inblock && /^    / { for (i = 1; i <= NF; i++) failed[$i] = 1; next }
  inblock { inblock = 0 }
  /^Result: / { result = substr($0, 9) }
  END {
    print "result " result
    for (f in failed) {
      n = split(named[f], ids, " ")
      if (n == 0 || !(f in plain)) print "id " bare(f)
      for (i = 1; i <= n; i++) print "id " ids[i]
    }
  }' "$t/log" > "$t/parsed"

result="$(sed -n 's/^result //p' "$t/parsed")"
sed -n 's/^id //p' "$t/parsed" | LC_ALL=C sort -u > "$t/failed"
LC_ALL=C comm -23 "$t/failed" "$t/flaky" > "$t/failing"
case "$result" in
  "") fail "the suite did not finish: its output has no Result: line (exit status $rc)" ;;
  SUCCESS) [ "$rc" -eq 0 ] || fail "the suite reported SUCCESS but exited $rc" ;;
  FAILURE) [ "$rc" -eq 2 ] || fail "the suite reported FAILURE but exited $rc"
           [ -s "$t/failed" ] || fail "the suite reported FAILURE but named no failed test" ;;
  *) fail "the suite's result was $result (exit status $rc)" ;;
esac

LC_ALL=C comm -23 "$t/failing" "$t/listed" > "$t/unlisted"
LC_ALL=C comm -13 "$t/failing" "$t/listed" > "$t/stale"
if [ -s "$t/unlisted" ] || [ -s "$t/stale" ]; then
  [ ! -s "$t/unlisted" ] || echo "FAIL: failed, and $known does not list: $(xargs < "$t/unlisted")"
  [ ! -s "$t/stale" ] || echo "FAIL: listed in $known, but did not fail: $(xargs < "$t/stale")"
  exit 1
fi
n() { wc -l < "$1" | tr -d ' '; }
echo "PASS: regrtest ($context): $(n "$t/failing") failing tests, exactly the ones $known lists;" \
  "$(LC_ALL=C comm -12 "$t/failed" "$t/flaky" | wc -l | tr -d ' ') of $(n "$t/flaky") flaky failed, $(n "$t/ignore") ignored"
