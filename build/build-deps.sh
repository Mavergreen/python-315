#!/bin/sh
# platform: macOS-only -- build/toolchain.sh gets clang22 and Recaulk from pkgs
#   usage: build/build-deps.sh --arch x86_64|arm64 --out DIR
#          Builds static SQLite, liblzma and libzstd for one arch with py_toolchain's clang22, SDK and
#          deployment target, from sources build/fetch-ingredient.sh verified. Replaces DIR/include with
#          their public headers and DIR/lib with exactly libsqlite3.a, liblzma.a and libzstd.a. Works
#          in $MAVERICKS_BUILD_ROOT/python-315/deps-<arch>, compiling each file in a hermetic
#          environment, with no make: xz's configure runs only to write its config.h.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"

usage() { echo "usage: build-deps.sh --arch x86_64|arm64 --out DIR" >&2; exit 2; }
arch=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) [ "$#" -ge 2 ] || usage; arch=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$arch" in x86_64|arm64) ;; *) usage ;; esac
[ -n "$out" ] || usage
case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac

py_toolchain "$arch"
case "$arch" in
  x86_64) host=x86_64-apple-darwin13 ;;
  arm64) host=aarch64-apple-darwin20 ;;
esac
build="$(uname -m | sed 's/^arm64$/aarch64/')-apple-darwin$(uname -r)"

work="$(py_build_root)/deps-$arch"
rm -rf "$work"
mkdir -p "$work/src" "$work/obj"

hermetic() {
  env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$CLANG22_BIN" \
    PKG_CONFIG=/usr/bin/false PKG_CONFIG_LIBDIR=/nonexistent \
    SDKROOT="$SDKROOT" MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" "$@"
}

compile() {
  _c_lib=$1; shift
  _c_flags=$1; shift
  mkdir -p "$work/obj/$_c_lib"
  for _c_src in "$@"; do
    _c_obj="$work/obj/$_c_lib/$(printf '%s' "${_c_src#"$work"/src/*/}" | tr / _).o"
    # shellcheck disable=SC2086
    hermetic $CC $_c_flags -c "$_c_src" -o "$_c_obj" || { echo "build-deps: could not compile $_c_src" >&2; exit 1; }
  done
}

archive() {
  _a_lib=$1
  rm -f "$work/$_a_lib.a"
  hermetic "$AR" --format=darwin rcs "$work/$_a_lib.a" "$work/obj/$_a_lib"/*.o
  _a_dups="$("$NM" -g --defined-only -P "$work/$_a_lib.a" | awk 'NF >= 2 && $1 !~ /:$/ && $2 != "C" { print $1 }' | sort | uniq -d)"
  [ -z "$_a_dups" ] || { echo "build-deps: $_a_lib.a defines these more than once: $_a_dups" >&2; exit 1; }
}

sqlite="$(sh "$here/fetch-ingredient.sh" sqlite --dest "$work/src")"
compile libsqlite3 "-O2 -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MATH_FUNCTIONS -DHAVE_USLEEP=1 -DHAVE_LOCALTIME_R=1" \
  "$sqlite/sqlite3.c"
archive libsqlite3

xz="$(sh "$here/fetch-ingredient.sh" xz --dest "$work/src")"
mkdir -p "$work/xz-config"
( cd "$work/xz-config" && hermetic CC="$CC" AR="$AR" RANLIB="$RANLIB" NM="$NM" CFLAGS=-O2 \
    STRIP=: LIPO=: OTOOL=: OTOOL64=: NMEDIT=: DSYMUTIL=: MAKE=/usr/bin/false \
    /bin/sh "$xz/configure" --build="$build" --host="$host" --disable-shared --enable-static \
      --disable-dependency-tracking --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
      --disable-lzma-links --disable-scripts --disable-doc --disable-nls --enable-threads=posix \
    > "$work/xz-configure.log" 2>&1 ) || {
  tail -30 "$work/xz-configure.log" >&2; echo "build-deps: xz's configure failed ($work/xz-configure.log)" >&2; exit 1; }
xz_cflags="$(sed -n 's/^CFLAGS = //p; s/^AM_CFLAGS = //p' "$work/xz-config/Makefile" | tr '\n' ' ')"
L="$xz/src/liblzma"
# spec: xz's src/liblzma/Makefile.am and its */Makefile.inc -- configure's defaults compile every
#       liblzma source except the --enable-small variants, the table generators and x86-32 assembly.
xz_srcs="$(for d in common check lz lzma rangecoder delta simple; do ls "$L/$d"/*.c; done \
  | grep -v -E '_small\.c$|tablegen\.c$|_gen\.c$')"
# shellcheck disable=SC2086
compile liblzma "$xz_cflags -DHAVE_CONFIG_H -I$work/xz-config -I$L/api -I$L/common -I$L/check -I$L/lz -I$L/rangecoder -I$L/lzma -I$L/delta -I$L/simple -I$xz/src/common -DTUKLIB_SYMBOL_PREFIX=lzma_" \
  $xz_srcs "$xz/src/common/tuklib_physmem.c" "$xz/src/common/tuklib_cpucores.c"
archive liblzma

zstd="$(sh "$here/fetch-ingredient.sh" zstd --dest "$work/src")"
Z="$zstd/lib"
# spec: zstd's lib/Makefile and lib/libzstd.mk -- the default library: common, compress, decompress,
#       dictBuilder and legacy v0.5-v0.7, with x86-64 assembly; multithreaded like its dylib.
zstd_srcs="$(ls "$Z"/common/*.c "$Z"/compress/*.c "$Z"/decompress/*.c "$Z"/dictBuilder/*.c "$Z"/legacy/zstd_v0[5-7].c)"
[ "$arch" != x86_64 ] || zstd_srcs="$zstd_srcs $(ls "$Z"/decompress/*_amd64.S)"
# shellcheck disable=SC2086
compile libzstd "-O3 -DXXH_NAMESPACE=ZSTD_ -DDEBUGLEVEL=0 -DZSTD_LEGACY_SUPPORT=5 -DZSTD_MULTITHREAD -I$Z -I$Z/common -I$Z/legacy" \
  $zstd_srcs
archive libzstd

rm -rf "$out/include" "$out/lib"
mkdir -p "$out/include/lzma" "$out/lib"
cp "$sqlite/sqlite3.h" "$sqlite/sqlite3ext.h" "$L/api/lzma.h" "$Z/zstd.h" "$Z/zdict.h" "$Z/zstd_errors.h" "$out/include/"
cp "$L"/api/lzma/*.h "$out/include/lzma/"
cp "$work/libsqlite3.a" "$work/liblzma.a" "$work/libzstd.a" "$out/lib/"
echo "build-deps: $arch archives and headers in $out"
