#!/bin/sh
# platform: host-agnostic
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/regrtest.sh"
fx="$here/fixtures/regrtest"
t="$(mktemp -d "${TMPDIR:-/tmp}/regrtest-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT

cat > "$t/python" <<'EOF'
#!/bin/sh
if [ "$1" = -I ]; then
  [ -z "$FAKE_PREFIX_FAILS" ] || exit 1
  printf '%s\n%s\n' "${FAKE_REAL_PREFIX:-/stage/usr/local/mavergreen/python315}" "${FAKE_CONFIG_PREFIX:-/nonexistent/python315}"
  exit 0
fi
printf '%s\n' "$*" > "$FAKE_ARGS"
printf '%s\n' "$0" > "$FAKE_ARGS.0"
cat "$FAKE_LOG"
exit "$FAKE_RC"
EOF
chmod +x "$t/python"
ctx=""; real=""; config=""; qfail=""
run() { rm -f "$t/args"; REGRTEST_CONTEXT="$ctx" FAKE_REAL_PREFIX="$real" FAKE_CONFIG_PREFIX="$config" FAKE_PREFIX_FAILS="$qfail" FAKE_ARGS="$t/args" FAKE_LOG="$1" FAKE_RC="$2" sh "$script" "$t/python" "$t/known" > "$t/out" 2>&1; }
says() { grep -q -e "$1" "$t/out" || { echo "FAIL $2: wanted \"$1\" in: $(cat "$t/out")"; exit 1; }; }
all="$fx/known-failures.txt"

cp "$all" "$t/known"
run "$fx/failure.log" 2 || { echo "FAIL exact match: $(cat "$t/out")"; exit 1; }
says '^PASS: regrtest (stage): 5 failing tests' "exact match"
[ "$(cat "$t/args")" = "-m test -j0 -W --timeout 600 -uall,-network,-gui,-audio,-largefile" ] || {
  echo "FAIL the suite ran as: $(cat "$t/args")"; exit 1; }
[ "$(cat "$t/args.0")" = "$(cd -P "$t" && pwd -P)/python" ] || {
  echo "FAIL ran $(cat "$t/args.0"), not the python by its physical path (unittest's discovery tests fail under a symlinked prefix such as /var)"; exit 1; }

grep -v test_name_resolution "$all" > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL an unlisted failure passed"; exit 1; fi
says 'does not list: test_pkgutil.PkgutilTests.test_name_resolution$' "unlisted failure"

grep -v test_crashy "$all" > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL an unlisted crash passed"; exit 1; fi
says 'does not list: test_crashy$' "unlisted crash"

grep -v test_large_sys_argv "$all" > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL an unlisted failure in a split test passed"; exit 1; fi
says 'does not list: test_multiprocessing_forkserver.test_processes.WithProcessesTestProcess.test_large_sys_argv$' "unlisted split"

{ cat "$all"; echo 'test_os.ExecTests.test_execve_env_concurrent_mutation  # canned: now passes'; } > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL a stale listing passed"; exit 1; fi
says 'did not fail: test_os.ExecTests.test_execve_env_concurrent_mutation$' "stale listing"

: > "$t/known"
run "$fx/success.log" 0 || { echo "FAIL a clean run with an empty list: $(cat "$t/out")"; exit 1; }
says '^PASS: regrtest (stage): 0 failing tests' "clean run"
echo 'test_math.FMATests.test_fma_zero_result  # canned' > "$t/known"
if run "$fx/success.log" 0; then echo "FAIL a stale listing on a clean run passed"; exit 1; fi
says 'did not fail: test_math.FMATests.test_fma_zero_result$' "stale on a clean run"

grep -v '^Result:' "$fx/failure.log" > "$t/truncated.log"
cp "$all" "$t/known"
if run "$t/truncated.log" 2; then echo "FAIL a run with no Result: line passed"; exit 1; fi
says 'did not finish' "truncated"
if run "$fx/failure.log" 0; then echo "FAIL FAILURE with exit status 0 passed"; exit 1; fi
says 'reported FAILURE but exited 0' "status mismatch"
if run "$fx/success.log" 2; then echo "FAIL SUCCESS with exit status 2 passed"; exit 1; fi
says 'reported SUCCESS but exited 2' "status mismatch"
sed '/tests failed:$/,/^$/d' "$fx/failure.log" > "$t/unnamed.log"
: > "$t/known"
if run "$t/unnamed.log" 2; then echo "FAIL a FAILURE naming no test passed"; exit 1; fi
says 'named no failed test' "FAILURE naming nothing"

esc="$(printf '\033')"
sed -e "s/^\(Result: \)\(FAILURE\)/\1${esc}[1;31m\2${esc}[0m/" -e "s/^\(4 tests failed:\)/${esc}[1;31m\1${esc}[0m/" \
  "$fx/failure.log" > "$t/colored.log"
cp "$all" "$t/known"
run "$t/colored.log" 2 || { echo "FAIL colored output: $(cat "$t/out")"; exit 1; }

{ cat "$all"; echo 'test_os.ExecTests.test_whatever'; } > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL a listing with no reason passed"; exit 1; fi
says 'line 7 is not' "no reason"
[ ! -e "$t/args" ] || { echo "FAIL the suite ran despite a malformed list"; exit 1; }
{ cat "$all"; echo 'test_crashy  # again'; } > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL a duplicate listing passed"; exit 1; fi
says 'lists test_crashy again' "duplicate"

sed 's/^test_crashy /stage: test_crashy /' "$all" > "$t/known"
ctx=stage; run "$fx/failure.log" 2 || { echo "FAIL a stage: failure from a stage: $(cat "$t/out")"; exit 1; }
ctx=""; run "$fx/failure.log" 2 || { echo "FAIL a stage: failure, default context: $(cat "$t/out")"; exit 1; }
says '^PASS: regrtest (stage)' "default context for a python outside /usr/local/mavergreen"
ctx=installed
if run "$fx/failure.log" 2; then echo "FAIL a stage: failure passed in an installed tree"; exit 1; fi
says 'does not list: test_crashy$' "stage: when installed"
{ cat "$all"; echo 'stage: test_os.ExecTests.test_whatever  # canned: fails only from a stage'; } > "$t/known"
run "$fx/failure.log" 2 || { echo "FAIL a passing stage: test, installed: $(cat "$t/out")"; exit 1; }
ctx=stage
if run "$fx/failure.log" 2; then echo "FAIL a stage: test that passed from a stage passed the gate"; exit 1; fi
says 'did not fail: test_os.ExecTests.test_whatever$' "stale stage:"
ctx=bogus; rc=0; run "$fx/failure.log" 2 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL REGRTEST_CONTEXT=bogus exited $rc, not 2"; exit 1; }
ctx=""

{ sed 's/^test_crashy /flaky: test_crashy /' "$all"; echo 'flaky: test_os.ExecTests.test_whatever  # canned: sometimes fails'; } > "$t/known"
run "$fx/failure.log" 2 || { echo "FAIL flaky: tests, one failing and one passing: $(cat "$t/out")"; exit 1; }
says '1 of 2 flaky failed' "flaky count"
grep -v test_crashy "$all" | sed 's/^test_math/flaky: test_math/' > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL flaky: lines hid an unlisted failure"; exit 1; fi
says 'does not list: test_crashy$' "flaky: hides only itself"

r='ignore: test_tarfile.TestExtractionFilters.test_realpath_limit_attack  # canned: breaks the run'
{ cat "$all"; echo "$r. Revisit when it no longer does."; } > "$t/known"
run "$fx/failure.log" 2 || { echo "FAIL an ignore: line: $(cat "$t/out")"; exit 1; }
says ', 1 ignored$' "ignore count"
[ "$(cat "$t/args")" = "-m test -j0 -W --timeout 600 -uall,-network,-gui,-audio,-largefile --ignore test.test_tarfile.TestExtractionFilters.test_realpath_limit_attack" ] || {
  echo "FAIL an ignore: line ran the suite as: $(cat "$t/args")"; exit 1; }
{ cat "$all"; echo "$r."; } > "$t/known"
if run "$fx/failure.log" 2; then echo "FAIL an ignore: line with no exit passed"; exit 1; fi
says 'without saying when to revisit it' "ignore: with no exit"
[ ! -e "$t/args" ] || { echo "FAIL the suite ran despite an ignore: with no exit"; exit 1; }

sed 's/\] test_math failed (2 failures)$/] test_math worker non-zero exit code (Exit code -11)/' "$fx/failure.log" > "$t/crash.log"
cmp -s "$t/crash.log" "$fx/failure.log" && { echo "FAIL the crash fixture did not change"; exit 1; }
cp "$all" "$t/known"
if run "$t/crash.log" 2; then echo "FAIL a worker that crashed after its listed failures passed"; exit 1; fi
says 'does not list: test_math$' "listed failures, then a crash"
{ cat "$all"; echo 'test_math  # canned: its worker crashes after the tests'; } > "$t/known"
run "$t/crash.log" 2 || { echo "FAIL a listed crash: $(cat "$t/out")"; exit 1; }
sed 's/\] test_pkgutil failed (1 error)$/] test_pkgutil failed (uncaught exception)/' "$fx/failure.log" > "$t/uncaught.log"
cp "$all" "$t/known"
if run "$t/uncaught.log" 2; then echo "FAIL an uncaught exception after a listed failure passed"; exit 1; fi
says 'does not list: test_pkgutil$' "listed failure, then an uncaught exception"

mkdir "$t/inst"; inst="$(cd -P "$t/inst" && pwd -P)"; ln -s "$inst" "$t/inst-link"
real="$inst"; config="$t/inst-link"
run "$fx/failure.log" 2 || { echo "FAIL a python at its configured prefix: $(cat "$t/out")"; exit 1; }
says '^PASS: regrtest (installed)' "default context for a python at its configured prefix"
real=""
if run "$fx/failure.log" 2; then echo "FAIL a stage run passed on a host with the prefix installed"; exit 1; fi
says 'is installed tests that installed libpython' "stage run beside an install"
ctx=stage
if run "$fx/failure.log" 2; then echo "FAIL REGRTEST_CONTEXT=stage passed on a host with the prefix installed"; exit 1; fi
ctx=installed
run "$fx/failure.log" 2 || { echo "FAIL REGRTEST_CONTEXT=installed beside an install: $(cat "$t/out")"; exit 1; }
ctx=""; config=""; qfail=1
if run "$fx/failure.log" 2; then echo "FAIL a python that cannot report its prefix passed"; exit 1; fi
says 'could not report its prefix' "prefix query fails"
qfail=""

rc=0; sh "$script" > "$t/out" 2>&1 || rc=$?
[ "$rc" -eq 77 ] || { echo "FAIL no arguments exited $rc, not 77"; exit 1; }

echo "PASS: regrtest comparator (canned output)"
