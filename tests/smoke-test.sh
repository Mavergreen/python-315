#!/bin/sh
# platform: macOS-only -- reads the stage's Mach-O with clang22's llvm tools, and runs it
#   usage: PY_STAGE=DIR tests/smoke-test.sh
#          Checks the python315 tree build-python.sh staged under DIR. Exits 77 when PY_STAGE is unset, and
#          when this host cannot execute the stage's arch (after its static checks pass).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
fail() { echo "FAIL: $*"; exit 1; }

[ -n "${PY_STAGE:-}" ] || { echo "SKIP: set PY_STAGE to a stage from build/build-python.sh"; exit 77; }
prefix="$PY_STAGE/usr/local/mavergreen/python315"
py="$prefix/bin/python3.15"
[ -x "$py" ] || fail "no $py"
t="$(mktemp -d "${TMPDIR:-/tmp}/smoke-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
py_toolchain "$(uname -m)" >/dev/null
B="$CLANG22_BIN"

archs="$("$B/llvm-lipo" -info "$py" | sed -n 's/.*: //p' | xargs)" || fail "llvm-lipo cannot read $py"
[ -n "$archs" ] || fail "llvm-lipo found no arch in $py"
find "$prefix" -type f -exec /usr/bin/file {} + | sed -n -e 's/: *Mach-O.*//p' -e 's/: *current ar archive.*//p' | sort -u > "$t/macho"
[ -s "$t/macho" ] || fail "no Mach-O files under $prefix"
grep -qx "$py" "$t/macho" || fail "the Mach-O scan missed $py"

if grep -q ' ' "$t/macho"; then fail "a Mach-O path has a space: $(grep ' ' "$t/macho")"; fi
MAVERICKS_ALLOW_ARCHS="$archs" MAVERICKS_DEVIATIONS_ROOT="$MAVERICKS_ROOT" \
  LIPO="$B/llvm-lipo" OTOOL="$B/llvm-otool" NM="$B/llvm-nm" STRINGS="$B/llvm-strings" \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" $(cat "$t/macho") > "$t/guard.log" 2>&1 || {
    tail -40 "$t/guard.log"; fail "the compat guard refused the stage"; }

: > "$t/leaks"; : > "$t/names"; : > "$t/unsigned"
host="$(uname -m)"
signed=0
check_arm64_signature() {
  _info="$("$B/llvm-lipo" -info "$1")" || fail "llvm-lipo cannot read $1"
  case "$_info" in *arm64*) ;; *) return 0 ;; esac
  _slice="$1"
  case "$_info" in
    Architectures*) "$B/llvm-lipo" -thin arm64 "$1" -output "$t/slice" || fail "llvm-lipo cannot thin $1"; _slice="$t/slice" ;;
  esac
  "$B/llvm-otool" -hv "$_slice" | grep -q -E ' (EXECUTE|DYLIB|BUNDLE) ' || return 0
  signed=$((signed + 1))
  "$B/llvm-otool" -l "$_slice" | grep -q 'cmd LC_CODE_SIGNATURE$' || echo "$1: no LC_CODE_SIGNATURE" >> "$t/unsigned"
  if [ "$host" = arm64 ] && [ -x /usr/bin/codesign ]; then
    /usr/bin/codesign --verify -a arm64 "$1" 2>> "$t/unsigned" || echo "$1: codesign --verify failed" >> "$t/unsigned"
  fi
}
while read -r f; do
  "$B/llvm-strings" "$f" > "$t/strings" || fail "llvm-strings cannot read $f"
  [ -s "$t/strings" ] || fail "llvm-strings found no strings in $f"
  sed 's|/usr/local/mavergreen/||g' "$t/strings" \
    | grep -E '/opt/pkg|/opt/local|/opt/homebrew|(^|[^A-Za-z0-9_.])/sw/|/usr/local/' | sed "s|^|$f: |" >> "$t/leaks" || true
  "$B/llvm-otool" -l "$f" > "$t/lc" || fail "llvm-otool cannot read $f"
  awk -v f="$f" '
    $1 == "cmd" { c = $2 }
    $1 == "name" && c ~ /^LC_(ID|LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD|LOAD_UPWARD)_DYLIB$/ { print f ": " c " " $2 }
    $1 == "path" && c == "LC_RPATH" { print f ": " c " " $2 }' "$t/lc" >> "$t/names"
  check_arm64_signature "$f"
done < "$t/macho"
[ ! -s "$t/leaks" ] || { cat "$t/leaks"; fail "a Mach-O names a contaminating prefix"; }
grep -q 'LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib$' "$t/names" || fail "the load-command scan found no libSystem"
bad="$(grep -v -E ' (@rpath|@executable_path|@loader_path)/| /usr/lib/| /System/' "$t/names" || true)"
[ -z "$bad" ] || { printf '%s\n' "$bad"; fail "an install name or load command is absolute outside /usr/lib and /System"; }
cxx="$(grep -E 'libc\+\+|libstdc\+\+' "$t/names" || true)"
[ -z "$cxx" ] || { printf '%s\n' "$cxx"; fail "the stage links a C++ runtime, but py_toolchain's CXX has no 10.9 libc++ handling"; }
if ls "$prefix"/bin/pip* > /dev/null 2>&1; then fail "the stage has a pip: $(ls "$prefix"/bin/pip*)"; fi
[ ! -s "$t/unsigned" ] || { cat "$t/unsigned"; fail "an arm64 Mach-O has no valid ad-hoc signature after the install-name rewrite"; }
sigs=""
case " $archs " in
  *" arm64 "*)
    [ "$signed" -gt 0 ] || fail "the signature check found no arm64 executable or library"
    sigs=", $signed arm64 ad-hoc signatures" ;;
esac
echo "PASS static: $(wc -l < "$t/macho" | tr -d ' ') Mach-O files ($archs): compat guard, no contaminating prefix, relative install names, no C++ runtime$sigs"

case " $archs " in
  *" $host "*) ;;
  *) echo "SKIP runtime: this $host host cannot run $archs natively, and this test never runs it under Rosetta (x86_64 runs on-target, in mavericks-vm)"; exit 77 ;;
esac

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
