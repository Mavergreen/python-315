#!/bin/sh
# platform: macOS-only -- runs the product's python, which is a macOS build
#   usage: PY_STAGE=DIR tests/smoke-runtime.sh
#          Runs the python315 tree under DIR (a stage from build/build-python.sh, or / for an installed
#          tree) on this host: every required module imports, the platform is right, ssl, _hashlib and
#          pip are absent, and hashlib works. Needs neither clang22 nor shipyard, so a bare 10.9 guest
#          runs it; tests/smoke-test.sh runs it after its static checks when this host can run the
#          stage's arch. Exits 77 when PY_STAGE is unset.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

[ -n "${PY_STAGE:-}" ] || { echo "SKIP: set PY_STAGE to a stage from build/build-python.sh, or / for an installed tree"; exit 77; }
py="${PY_STAGE%/}/usr/local/mavergreen/python315/bin/python3.15"
[ -x "$py" ] || fail "no $py"
t="$(mktemp -d "${TMPDIR:-/tmp}/smoke-runtime.XXXXXX")"
trap 'rm -rf "$t"' EXIT

run() { env -i HOME="$t" PATH=/usr/bin:/bin "$py" -I "$@"; }
while read -r m; do
  run -c "import $m" > "$t/imp" 2>&1 || { cat "$t/imp"; fail "import $m"; }
done < "$here/fixtures/required-modules.txt"
mac="$(run -c 'import platform; print(platform.mac_ver()[0])')"
[ -n "$mac" ] || fail "platform.mac_ver() is empty"
machine="$(run -c 'import platform; print(platform.machine())')"
case "$machine" in
  x86_64) want=macosx-10.9-x86_64 ;;
  arm64) want=macosx-11.0-arm64 ;;
  *) fail "platform.machine() is '$machine'" ;;
esac
plat="$(run -c 'import sysconfig; print(sysconfig.get_platform())')"
[ "$plat" = "$want" ] || fail "sysconfig.get_platform() is '$plat', not '$want'"
for m in ssl _ssl _hashlib; do
  run -c "
try:
    import $m
except ModuleNotFoundError:
    pass
else:
    raise SystemExit('$m imported')" > "$t/imp" 2>&1 || { cat "$t/imp"; fail "import $m did not raise ModuleNotFoundError"; }
done
if run -m pip --version > "$t/pip" 2>&1; then fail "python3.15 -m pip succeeded: $(cat "$t/pip")"; fi
grep -q 'No module named pip' "$t/pip" || fail "python3.15 -m pip said: $(cat "$t/pip")"
sha="$(run -c 'import hashlib; print(hashlib.sha256(b"").hexdigest())')"
[ "$sha" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ] || fail "hashlib.sha256(b'') is '$sha'"
echo "PASS runtime ($machine on $mac): $(wc -l < "$here/fixtures/required-modules.txt" | tr -d ' ') required modules import, $plat, no ssl, no _hashlib, no pip, sha256 works"
