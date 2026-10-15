#!/bin/sh
# platform: macOS-only -- build/toolchain.sh gets clang22 from a pkg
#   usage: build/build-make.sh
#          Prints the path of a GNU make built from the release components/make/version pins, for this
#          host's arch, by py_toolchain's clang22 in a hermetic environment, with make's own build.sh,
#          so building it needs no make. Reuses $MAVERICKS_BUILD_ROOT/python-315/tools/make-<version>
#          when the same make and clang22 pins built it; concurrent runs replace it atomically. Build
#          output goes to stderr.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"
. "$here/hermetic-env.sh"

[ "$#" -eq 0 ] || { echo "usage: build-make.sh" >&2; exit 2; }
arch="$(uname -m)"
py_toolchain "$arch" >&2
v="$(sed -n 's/^VERSION=//p' "$MAVERICKS_ROOT/components/make/version" | tr -d '[:space:]')"
[ -n "$v" ] || { echo "build-make: components/make/version names no VERSION" >&2; exit 1; }
want="$(cat "$MAVERICKS_ROOT/components/make/version") clang22=$(py_pin clang22)"
dir="$(py_build_root)/tools/make-$v"
if [ -x "$dir/bin/make" ] && [ "$(cat "$dir.stamp" 2>/dev/null)" = "$want" ]; then
  printf '%s\n' "$dir/bin/make"; exit 0
fi

mkdir -p "$dir/bin"
work="$(mktemp -d "$(py_build_root)/make-build.XXXXXX")"
src="$(sh "$here/fetch-ingredient.sh" make --dest "$work/src")"
triple="$(printf '%s' "$arch" | sed 's/^arm64$/aarch64/')-apple-darwin$(uname -r)"
mkdir -p "$work/obj"
( cd "$work/obj" && py_hermetic CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS=-O2 MAKE=/usr/bin/false \
    /bin/sh "$src/configure" --build="$triple" --host="$triple" --prefix="$dir" \
      --disable-nls --without-guile --disable-dependency-tracking ) > "$work/configure.log" 2>&1 || {
  tail -30 "$work/configure.log" >&2; echo "build-make: make's configure failed ($work/configure.log)" >&2; exit 1; }
( cd "$work/obj" && py_hermetic /bin/sh "$src/build.sh" ) > "$work/build.log" 2>&1 || {
  tail -30 "$work/build.log" >&2; echo "build-make: make's build.sh failed ($work/build.log)" >&2; exit 1; }
got="$("$work/obj/make" --version | sed -n 1p)"
[ "$got" = "GNU Make $v" ] || { echo "build-make: the built make says '$got', not 'GNU Make $v'" >&2; exit 1; }
cp "$work/obj/make" "$dir/bin/make.$$"
mv -f "$dir/bin/make.$$" "$dir/bin/make"
printf '%s\n' "$want" > "$dir.stamp.$$"
mv -f "$dir.stamp.$$" "$dir.stamp"
rm -rf "$work"
printf '%s\n' "$dir/bin/make"
