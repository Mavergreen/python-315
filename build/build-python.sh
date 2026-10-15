#!/bin/sh
# platform: macOS-only -- build/toolchain.sh gets clang22 and Recaulk from pkgs
#   usage: build/build-python.sh --arch x86_64|arm64 [--build-python PATH] --stage DIR
#          Builds CPython (UPSTREAM_VERSION) for one arch with py_toolchain's clang22, the static deps from
#          build-deps.sh and, for x86_64, Recaulk, every step in a hermetic environment, and installs it
#          to DIR/usr/local/mavergreen/python315 with install names relative to the tree. An arch other
#          than this host's is a cross build and needs --build-python: a python3.15 of the same version
#          that runs here; only x86_64 cross-builds. Works in a fresh
#          $MAVERICKS_BUILD_ROOT/python-315/cpython-<arch>.XXXXXX, kept only on failure.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"
. "$here/hermetic-env.sh"

usage() { echo "usage: build-python.sh --arch x86_64|arm64 [--build-python PATH] --stage DIR" >&2; exit 2; }
die() { echo "build-python: $*" >&2; exit 1; }
arch=""; build_python=""; stage=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) [ "$#" -ge 2 ] || usage; arch=$2; shift 2 ;;
    --build-python) [ "$#" -ge 2 ] || usage; build_python=$2; shift 2 ;;
    --stage) [ "$#" -ge 2 ] || usage; stage=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$arch" in x86_64|arm64) ;; *) usage ;; esac
[ -n "$stage" ] || usage
case "$stage" in /*) ;; *) stage="$(pwd)/$stage" ;; esac

prefix=/usr/local/mavergreen/python315
host_arch="$(uname -m)"
build="$(printf '%s' "$host_arch" | sed 's/^arm64$/aarch64/')-apple-darwin$(uname -r)"
cross=""
regen="PYTHON_FOR_REGEN=/usr/bin/false"
if [ "$arch" = "$host_arch" ]; then
  host="$build"
else
  [ "$arch" = x86_64 ] || die "--arch $arch on this $host_arch host: only x86_64 cross-builds (configure's run-test answers below were measured for it); build $arch on a $arch Mac"
  host=x86_64-apple-darwin13
  [ -n "$build_python" ] || die "--arch $arch on this $host_arch host is a cross build, which needs --build-python"
  [ -x "$build_python" ] || die "--build-python $build_python is not an executable"
  want="$(tr -d '[:space:]' < "$MAVERICKS_ROOT/UPSTREAM_VERSION")"
  got="$(env -i PATH=/usr/bin:/bin "$build_python" -I -c 'import platform; print(platform.python_version())')" \
    || die "--build-python $build_python does not run here"
  [ "$got" = "$want" ] || die "--build-python $build_python is Python $got, not $want"
  darwin_run_test_answers="ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no ac_cv_buggy_getaddrinfo=no
    ac_cv_computed_gotos=yes ac_cv_aligned_required=no ac_cv_working_tzset=yes
    ac_cv_pthread_system_supported=yes ac_cv_pthread_is_default=yes"
  cross="--with-build-python=$build_python $darwin_run_test_answers"
  regen=""
fi

py_toolchain "$arch"
make="$(sh "$here/build-make.sh")"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
mkdir -p "$(py_build_root)"
work="$(mktemp -d "$(py_build_root)/cpython-$arch.XXXXXX")"
mkdir -p "$work/build/Modules"

sh "$here/build-deps.sh" --arch "$arch" --out "$work/deps" >&2
src="$(sh "$here/fetch-cpython.sh" --dest "$work/src")"
for p in "$MAVERICKS_ROOT"/patches/*.patch; do
  [ -f "$p" ] || continue
  ( cd "$src" && /usr/bin/patch -s -p1 -V none -F 0 < "$p" ) || die "${p##*/} does not apply"
done

# platform: HFS+ keeps mtimes in whole seconds, so make ignores a Modules/Setup.local written in the
#           same second as the Makefile configure writes
printf '*disabled*\n_ssl\n_hashlib\n_tkinter\n_gdbm\n' > "$work/build/Modules/Setup.local"

cppflags="-I$work/deps/include"
ldflags="-L$work/deps/lib -Wl,-headerpad_max_install_names"
libs=""
if [ "$arch" = x86_64 ]; then
  cppflags="$cppflags -isystem $RECAULK_INCLUDE"
  ldflags="$ldflags -Wl,-dead_strip_dylibs -Wl,-unexported_symbol,___recaulk_*"
  libs="$RECAULK_LIB -framework CoreFoundation -framework Security -framework CoreServices -framework IOKit -lobjc"
fi

# shellcheck disable=SC2086
( cd "$work/build" && py_hermetic /bin/sh "$src/configure" --build="$build" --host="$host" --prefix="$prefix" \
    --enable-shared --without-ensurepip --with-readline=editline --without-system-libmpdec \
    --without-static-libpython --with-openssl=/nonexistent $cross $regen \
    CC="$CC" CPP="$CC -E" CXX="$CXX" AR="$AR" \
    CPPFLAGS="$cppflags" LDFLAGS="$ldflags" LIBS="$libs" ) > "$work/configure.log" 2>&1 || {
  tail -40 "$work/configure.log" >&2; die "configure failed ($work/configure.log)"; }
plat=""
[ -z "$cross" ] || plat="_PYTHON_HOST_PLATFORM=macosx-$MACOSX_DEPLOYMENT_TARGET-$arch"
# shellcheck disable=SC2086
( cd "$work/build" && py_hermetic "$make" -j"$jobs" $plat ) > "$work/make.log" 2>&1 || {
  tail -40 "$work/make.log" >&2; die "make failed ($work/make.log)"; }
rm -rf "${stage:?}$prefix"
# shellcheck disable=SC2086
( cd "$work/build" && py_hermetic "$make" install DESTDIR="$stage" $plat ) > "$work/install.log" 2>&1 || {
  tail -40 "$work/install.log" >&2; die "make install failed ($work/install.log)"; }

tree="$stage$prefix"
lib="libpython$(tr -d '[:space:]' < "$MAVERICKS_ROOT/UPSTREAM_VERSION" | cut -d. -f1,2).dylib"
[ -f "$tree/lib/$lib" ] || die "make install left no lib/$lib"
INT="$CLANG22_BIN/llvm-install-name-tool"
"$INT" -id "@rpath/$lib" "$tree/lib/$lib"
find "$tree" -type f -exec /usr/bin/file {} + | sed -n 's/: *Mach-O.*//p' | while read -r f; do
  "$CLANG22_BIN/llvm-otool" -L "$f" | sed 1d | awk '{print $1}' | grep -qx "$prefix/lib/$lib" || continue
  rel="${f#"$tree"/}"
  up="$(printf '%s\n' "${rel%/*}" | sed 's|[^/][^/]*|..|g')"
  if "$CLANG22_BIN/llvm-otool" -hv "$f" | grep -q EXECUTE; then
    "$INT" -change "$prefix/lib/$lib" "@rpath/$lib" -add_rpath "@executable_path/$up/lib" -add_rpath "$prefix/lib" "$f"
  else
    "$INT" -change "$prefix/lib/$lib" "@rpath/$lib" -add_rpath "@loader_path/$up/lib" "$f"
  fi
done
if [ "$arch" = arm64 ] && [ -x /usr/bin/codesign ]; then
  find "$tree" -type f -exec /usr/bin/file {} + | sed -n 's/: *Mach-O.*//p' | while read -r f; do
    "$CLANG22_BIN/llvm-otool" -hv "$f" | grep -q -E 'EXECUTE|DYLIB|BUNDLE' || continue
    /usr/bin/codesign --verify -a arm64 "$f" 2>/dev/null && continue
    echo "build-python: re-signing $f ad hoc: its signature did not survive the install-name rewrite" >&2
    /usr/bin/codesign --force --sign - -a arm64 "$f"
  done
fi
rm -rf "$work"
echo "build-python: $arch staged at $tree" >&2
