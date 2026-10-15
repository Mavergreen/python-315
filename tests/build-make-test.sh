#!/bin/sh
# platform: macOS-only -- build-make.sh gets clang22 from a pkg, and make is read as Mach-O
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/build-make-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

arch="$(uname -m)"
why="$(py_toolchain_can_build "$arch")" || { echo "SKIP: $why"; exit 77; }
v="$(sed -n 's/^VERSION=//p' "$MAVERICKS_ROOT/components/make/version" | tr -d '[:space:]')"

make="$(sh "$MAVERICKS_ROOT/build/build-make.sh" 2>"$t/err")" || { tail -30 "$t/err"; fail "build-make.sh exited non-zero"; }
[ -x "$make" ] || fail "build-make.sh printed '$make', which is not an executable"
got="$("$make" --version | sed -n 1p)"
[ "$got" = "GNU Make $v" ] || fail "make --version says '$got', not 'GNU Make $v'"

py_toolchain "$arch" >/dev/null
slices="$(LIPO="$CLANG22_BIN/llvm-lipo" OTOOL="$CLANG22_BIN/llvm-otool" sh "$SHIPYARD_SCRIPTS/macho-slices.sh" "$make")" \
  || fail "macho-slices.sh could not read $make"
[ "$(printf '%s\n' "$slices" | awk '{print $1}' | sort -u)" = "$arch" ] || fail "$make is not $arch only: $slices"
deps="$("$CLANG22_BIN/llvm-otool" -L "$make" | sed 1d | awk '{print $1}')"
for d in $deps; do
  case "$d" in /usr/lib/*) ;; *) fail "$make links $d" ;; esac
done

mkdir -p "$t/proj"
printf 'all: out.txt\nout.txt: in.txt\n\tcp in.txt $@\n' > "$t/proj/Makefile"
echo built > "$t/proj/in.txt"
env -i PATH=/usr/bin:/bin "$make" -C "$t/proj" > "$t/make.log" 2>&1 || { cat "$t/make.log"; fail "make could not run a Makefile"; }
[ "$(cat "$t/proj/out.txt")" = built ] || fail "make ran but did not build out.txt"
again="$(sh "$MAVERICKS_ROOT/build/build-make.sh" 2>/dev/null)"
[ "$again" = "$make" ] || fail "a second build-make.sh printed '$again', not '$make'"
echo "PASS: GNU Make $v for $arch, linking only /usr/lib, builds a target"
