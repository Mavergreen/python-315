#!/bin/sh
# platform: macOS-only -- build-deps.sh gets clang22 from a pkg, and the archives are read as Mach-O
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
. "$SHIPYARD_SCRIPTS/sdk-pins.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/build-deps-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL $arch: $*"; exit 1; }
skipped=""
for arch in x86_64 arm64; do
  if ! why="$(py_toolchain_can_build "$arch")"; then
    echo "SKIP $arch: $why"; skipped="$skipped $arch"; continue
  fi
  out="$t/$arch"
  sh "$MAVERICKS_ROOT/build/build-deps.sh" --arch "$arch" --out "$out" > "$t/$arch.log" 2>&1 || {
    tail -40 "$t/$arch.log"; fail "build-deps.sh exited non-zero"; }
  py_toolchain "$arch"
  libs="$(cd "$out/lib" && ls | sort | tr '\n' ' ')"
  [ "$libs" = "liblzma.a libsqlite3.a libzstd.a " ] || fail "lib/ holds '$libs', not exactly the three archives"
  for h in sqlite3.h lzma.h zstd.h; do [ -f "$out/include/$h" ] || fail "no include/$h"; done
  sqlite_n="$(sed -n 's/^#define SQLITE_VERSION_NUMBER *//p' "$out/include/sqlite3.h")"
  [ "${sqlite_n:-0}" -ge 3015002 ] || fail "SQLite $sqlite_n is older than the 3.15.2 CPython needs"
  for lib in libsqlite3.a liblzma.a libzstd.a; do
    slices="$(LIPO="$CLANG22_BIN/llvm-lipo" OTOOL="$CLANG22_BIN/llvm-otool" \
      sh "$SHIPYARD_SCRIPTS/macho-slices.sh" "$out/lib/$lib")" || fail "$lib: macho-slices.sh could not read it"
    [ -n "$slices" ] || fail "$lib: no slices"
    printf '%s\n' "$slices" > "$t/slices"
    while read -r s_arch s_ft s_minos s_sdk; do
      [ "$s_arch" = "$arch" ] || fail "$lib carries $s_arch"
      [ "$s_ft" = OBJECT ] || fail "$lib has a $s_ft member"
      [ "$s_minos" = "$MACOSX_DEPLOYMENT_TARGET" ] || fail "$lib records minos $s_minos, not $MACOSX_DEPLOYMENT_TARGET"
      why="$(shipyard_sdk_rule "$s_arch" "$s_ft" "$s_minos" "$s_sdk")" || fail "$lib: $why"
    done < "$t/slices"
    "$CLANG22_BIN/llvm-strings" "$out/lib/$lib" > "$t/strings" || fail "llvm-strings cannot read $lib"
    [ -s "$t/strings" ] || fail "llvm-strings found no strings in $lib, so the prefix scan would see nothing"
    leaks="$(grep -E '/opt/pkg|/opt/local|/opt/homebrew|/sw/|/usr/local/' "$t/strings" | grep -v '/usr/local/mavergreen/' || true)"
    [ -z "$leaks" ] || fail "$lib names a contaminating prefix: $leaks"
  done
  # shellcheck disable=SC2086
  $CC -I"$out/include" "$here/fixtures/deps-link.c" -o "$t/deps-link-$arch" \
    -Wl,-force_load,"$out/lib/liblzma.a" -Wl,-force_load,"$out/lib/libzstd.a" \
    -Wl,-force_load,"$out/lib/libsqlite3.a" > "$t/link.log" 2>&1 || {
      cat "$t/link.log"; fail "a program using every part of the three archives does not link"; }
  if [ "$(uname -m)" = "$arch" ]; then
    "$t/deps-link-$arch" > "$t/run.log" 2>&1 || { cat "$t/run.log"; fail "the linked program failed"; }
    sed "s/^/  $arch: /" "$t/run.log"
  else
    echo "  $arch: linked; not run, since this host is $(uname -m)"
  fi
  if [ "$arch" = x86_64 ]; then
    MAVERICKS_ALLOW_ARCHS=x86_64 MAVERICKS_DEVIATIONS_ROOT="$MAVERICKS_ROOT" \
      LIPO="$CLANG22_BIN/llvm-lipo" OTOOL="$CLANG22_BIN/llvm-otool" NM="$CLANG22_BIN/llvm-nm" \
      STRINGS="$CLANG22_BIN/llvm-strings" \
      sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$out"/lib/*.a > "$t/guard.log" 2>&1 || {
        cat "$t/guard.log"; fail "the compat guard refused the archives"; }
  fi
  echo "PASS $arch: three static archives, $arch only, minos $MACOSX_DEPLOYMENT_TARGET, pinned SDK, no dylib, no contaminating path, every member links"
done
if [ -n "$skipped" ]; then
  echo "SKIP:$skipped cannot be built on this host (reasons above)"
  exit 77
fi
echo "PASS: build-deps"
