#!/bin/sh
# platform: macOS-only -- build/build-updater.sh builds a Cocoa app
#   usage: tests/build-updater-test.sh
#          A toolchain that cannot be had stops build/build-updater.sh before CMake runs, even when the
#          caller's environment still holds another toolchain's CLANG22_BIN; and the host's own arch
#          builds under a build root whose path has a space.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
mkdir -p "$(py_build_root)"
t="$(mktemp -d "$(py_build_root)/updater-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }
arch="$(uname -m)"
py_toolchain "$arch" > /dev/null

mkdir -p "$t/repo"
cp -Rp "$MAVERICKS_ROOT/build" "$MAVERICKS_ROOT/components" "$MAVERICKS_ROOT/updater" \
  "$MAVERICKS_ROOT/CMakeLists.txt" "$MAVERICKS_ROOT/UPSTREAM_VERSION" "$t/repo/"
printf '%s\n' 0.0.0-mavericks.0 > "$t/repo/components/clang22/version"
if env CLANG22_BIN="$CLANG22_BIN" MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  sh "$t/repo/build/build-updater.sh" --arch "$arch" --out "$t/bad/python315-updater.app" > "$t/o" 2>&1; then
  fail "build-updater built with a clang22 pin that does not exist"
fi
grep -q "the $arch updater did not build" "$t/o" || fail "the refusal does not name the arch: $(cat "$t/o")"
grep -q 'compiler identification' "$t/o" && fail "CMake configured after py_toolchain failed: $(grep 'compiler identification' "$t/o")"
[ ! -e "$t/bad" ] || fail "a failed build left $t/bad behind"
echo "PASS refusal: a failing py_toolchain stops the build before CMake, despite a stale CLANG22_BIN"

root="$t/build root"; mkdir -p "$root"
MAVERICKS_BUILD_ROOT="$root" sh "$MAVERICKS_ROOT/build/build-updater.sh" --arch "$arch" \
  --out "$t/good/python315-updater.app" > "$t/o" 2>&1 || fail "build-updater failed under '$root': $(tail -5 "$t/o")"
exe="$t/good/python315-updater.app/Contents/MacOS/python315-updater"
[ "$(echo $("$CLANG22_BIN/llvm-lipo" -info "$exe" | sed -n 's/.*: //p'))" = "$arch" ] \
  || fail "the updater is not $arch: $("$CLANG22_BIN/llvm-lipo" -info "$exe")"
[ -z "$(ls "$root/python-315" | grep '^updater\.')" ] || fail "build-updater left its work directory behind"
echo "PASS: build-updater (refuses an unavailable toolchain before CMake; builds $arch under a build root with a space)"
