#!/bin/sh
# platform: macOS-only -- builds a Cocoa app against the macOS SDK
#   usage: build/build-updater.sh --arch x86_64|arm64 [--arch x86_64|arm64] --out APP
#          Builds the Sparkle updater (CMakeLists.txt) with py_toolchain's clang22 and shipyard's
#          MavericksToolchain.cmake, one configure per arch (x86_64: 10.9 SDK, minos 10.9; arm64: 11.3
#          SDK, minos 11.0), each in its own <arch>/ of one fresh
#          $MAVERICKS_BUILD_ROOT/python-315/updater.XXXXXX, removed afterwards. Two arches are merged
#          into one universal app with shipyard's lipo-merge-tree.sh. APP must not exist. Its version
#          is mavericks_resolve_version's, which reads VERSION when one exists.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"

usage() { echo "usage: build/build-updater.sh --arch x86_64|arm64 [--arch x86_64|arm64] --out APP" >&2; exit 2; }
die() { echo "build-updater: $*" >&2; exit 1; }
archs=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) [ "$#" -ge 2 ] || usage
      case "$2" in x86_64|arm64) ;; *) usage ;; esac
      case " $archs " in *" $2 "*) usage ;; esac
      archs="$archs $2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$archs" ] && [ -n "$out" ] || usage
case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac
[ ! -e "$out" ] && [ ! -L "$out" ] || die "$out already exists"
cmake_bin="$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)"
[ -x "$cmake_bin" ] || die "no shipyard-cmake; install the shipyard pkg"
tc="$(dirname "$SHIPYARD_SCRIPTS")/MavericksToolchain.cmake"
[ -f "$tc" ] || die "no MavericksToolchain.cmake beside $SHIPYARD_SCRIPTS"

mkdir -p "$(py_build_root)"
work="$(mktemp -d "$(py_build_root)/updater.XXXXXX")"
trap 'rm -rf "$work"' EXIT
for a in $archs; do
  ( py_toolchain "$a" > /dev/null \
    && "$cmake_bin" -S "$MAVERICKS_ROOT" -B "$work/$a" \
      -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_OSX_ARCHITECTURES="$a" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
      -DCMAKE_OBJC_COMPILER="$CLANG22_BIN/clang" -DCMAKE_OBJC_FLAGS=--no-default-config \
      -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld \
    && "$cmake_bin" --build "$work/$a" ) >&2 || die "the $a updater did not build"
done
app=python315-updater.app
mkdir -p "$(dirname "$out")"
case "$archs" in
  " x86_64" | " arm64") cp -Rp "$work/${archs# }/$app" "$out" ;;
  *)
    py_toolchain "$(uname -m)" > /dev/null
    mkdir "$work/bin"
    ln -s "$CLANG22_BIN/llvm-lipo" "$work/bin/lipo"
    PATH="$work/bin:$PATH" sh "$SHIPYARD_SCRIPTS/lipo-merge-tree.sh" --a "$work/x86_64/$app" \
      --b "$work/arm64/$app" --out "$out" --require-archs "x86_64 arm64" >&2 ;;
esac
echo "build-updater:$archs updater at $out" >&2
