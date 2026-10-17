#!/bin/sh
# platform: macOS-only -- runs the stage's python3.15, built for the Mac that builds it
#   usage: PY_STAGE=DIR tests/family-site-test.sh
#          Checks the .pth in the python315 tree build-python.sh staged under DIR. Exits 77 when PY_STAGE
#          is unset.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"
[ -n "${PY_STAGE:-}" ] || { echo "SKIP: set PY_STAGE to a stage from build/build-python.sh"; exit 77; }
ver="$(tr -d '[:space:]' < "$MAVERICKS_ROOT/UPSTREAM_VERSION" | cut -d. -f1,2)"
prefix="$PY_STAGE/usr/local/mavergreen/python315"
py="$prefix/bin/python$ver"
[ -x "$py" ] || { echo "FAIL no $py in PY_STAGE"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/family-site-test.XXXXXX")"
trap 'chmod -R u+rwx "$t" 2>/dev/null; rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }

root="$t/root"
fake="$root/fakeprod/lib/python$ver/site-packages"
mkdir -p "$fake" "$root/otherminor/lib/python3.0/site-packages"
echo 'where = "fake"' > "$fake/famtest.py"
echo 'where = "wrongminor"' > "$root/otherminor/lib/python3.0/site-packages/wrongminor.py"
ln -s "$t/nowhere" "$root/dangling"
mkdir -p "$root/locked/lib"; chmod 000 "$root/locked/lib"
mkdir -p "$root/zzlast/lib/python$ver/site-packages" "$root/aaa/lib/python$ver/site-packages"

run() { env -i HOME="$t" PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 "$@"; }

run MAVERGREEN_ROOT="$root" "$py" -c 'import famtest; assert famtest.where == "fake"' \
  || fail "a product's site-packages under MAVERGREEN_ROOT is not importable"
(cd "$t" && run MAVERGREEN_ROOT=root "$py" -c 'import sys; assert not [p for p in sys.path if p.startswith("root/")]') \
  || fail "a relative MAVERGREEN_ROOT put relative entries on sys.path"
run MAVERGREEN_ROOT="$root" "$py" -c 'import wrongminor' 2> /dev/null && fail "another minor's site-packages was added"
run MAVERGREEN_ROOT="$t/empty" "$py" -c 'import famtest' 2> /dev/null && fail "famtest imports with no fake product"
run MAVERGREEN_ROOT="$root" "$py" -E -c 'import famtest' 2> /dev/null && fail "-E did not ignore MAVERGREEN_ROOT"
run MAVERGREEN_ROOT="$root" "$py" -I -c 'import famtest' 2> /dev/null && fail "-I did not ignore MAVERGREEN_ROOT"
run MAVERGREEN_ROOT="$root" "$py" -S -c 'import famtest' 2> /dev/null && fail "-S ran the hook"

own="$prefix/lib/python$ver/site-packages"
n="$(run MAVERGREEN_ROOT="$root" "$py" -c 'import os, sys; print(sum(os.path.realpath(p) == os.path.realpath(sys.argv[1]) for p in sys.path))' "$own")"
[ "$n" = 1 ] || fail "python315's own site-packages appears $n times in sys.path"
own_root="$t/ownroot"
mkdir -p "$own_root"
ln -s "$prefix" "$own_root/python315"
n="$(run MAVERGREEN_ROOT="$own_root" "$py" -c 'import os, sys; print(sum(os.path.realpath(p) == os.path.realpath(sys.argv[1]) for p in sys.path))' "$own")"
[ "$n" = 1 ] || fail "with python315 under MAVERGREEN_ROOT its site-packages appears $n times"

run MAVERGREEN_ROOT="$root" "$py" -c '
import sys
i = [p for p in sys.path if p.startswith(sys.argv[1])]
assert [p.split("/")[-4] for p in i] == ["aaa", "fakeprod", "zzlast"], i
assert sys.path.index(i[0]) > max(n for n, p in enumerate(sys.path) if p.endswith("python315/lib/python" + sys.argv[2] + "/site-packages") or "mavergreen/python315" in p) , sys.path
' "$root" "$ver" || fail "family site-packages are not appended in product-name order"

out="$(run MAVERGREEN_ROOT="$root" "$py" -c 'print("started")' 2>&1)" || fail "a dangling symlink or unreadable product broke startup: $out"
[ "$out" = started ] || fail "startup printed: $out"
out="$(run MAVERGREEN_ROOT="$t/nonexistent" "$py" -c 'print("started")' 2>&1)" || fail "a missing root broke startup: $out"
[ "$out" = started ] || fail "a missing root made startup print: $out"
out="$(run MAVERGREEN_ROOT="$root/fakeprod/lib/python$ver/site-packages/famtest.py" "$py" -c 'print("started")' 2>&1)" \
  || fail "a root that is a file broke startup: $out"
[ "$out" = started ] || fail "a file as root made startup print: $out"

echo "PASS: family-site"
