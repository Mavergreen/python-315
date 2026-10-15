# platform: macOS-only -- fetch_product_pkg.sh expands the clang22 and Recaulk pkgs with pkgutil
#   usage: . build/toolchain.sh; py_toolchain x86_64|arm64
#          Exports CC, CXX, AR, RANLIB, NM, CLANG22, CLANG22_BIN, SDKROOT and MACOSX_DEPLOYMENT_TARGET
#          (10.9 or 11.0) for one arch; for x86_64 also RECAULK_LIB (the pinned librecaulk.a) and
#          RECAULK_INCLUDE, and for arm64 unsets them. clang22 is the release components/clang22/version
#          pins: on Mac OS X 10.9 the installed /usr/local/mavergreen/clang22, which must be that
#          release; elsewhere the clang22-cross pkg, extracted under the build root. CC never reads the
#          driver's .cfg: target, SDK (shipyard's fetch_sdk.sh pin) and linker (lld) are all explicit.
#          Recaulk is the release components/recaulk/version pins, extracted on every host.
#          py_toolchain_can_build ARCH prints why and returns 1 when this host cannot build ARCH.
: "${MAVERICKS_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
. "$MAVERICKS_ROOT/build/msc.sh"

py_build_root() { _pbr="${TMPDIR:-/tmp}"; printf '%s/python-315\n' "${MAVERICKS_BUILD_ROOT:-${_pbr%/}/mm-build}"; }

py_pin() { tr -d '[:space:]' < "$MAVERICKS_ROOT/components/$1/version"; }

py_host_is_109() { [ "$(uname -s)" = Darwin ] && [ "$(uname -r | cut -d. -f1)" = 13 ]; }

py_toolchain_can_build() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "clang22 and Recaulk arrive as pkgs, which only macOS can expand"; return 1
  fi
  case "${1:-}" in
    x86_64) return 0 ;;
    arm64)
      if py_host_is_109; then
        echo "clang22 on Mac OS X 10.9 has no AArch64 backend, so arm64 builds on a modern Mac"; return 1
      fi
      return 0 ;;
    *) echo "unknown arch '${1:-}' (x86_64 or arm64)"; return 1 ;;
  esac
}

py_installed_version() {
  awk '/<key>version<\/key>/ { getline; sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit }' "$1/mavergreen.plist" 2>/dev/null
}

py_fetch_pkg() {
  _pf_short=$1; _pf_ver=$2; _pf_dest=$3; _pf_asset=${4:-}
  if [ -d "$_pf_dest" ] && [ "$(cat "$_pf_dest.pin" 2>/dev/null)" = "$_pf_ver" ]; then return 0; fi
  rm -f "$_pf_dest.pin"
  if [ -n "$_pf_asset" ]; then
    sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "$_pf_asset" "$_pf_short" "$_pf_ver" "$_pf_dest" >/dev/null || return 1
  else
    sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" "$_pf_short" "$_pf_ver" "$_pf_dest" >/dev/null || return 1
  fi
  printf '%s\n' "$_pf_ver" > "$_pf_dest.pin"
}

py_toolchain() {
  _pt_why="$(py_toolchain_can_build "${1:-}")" || { echo "py_toolchain: $_pt_why" >&2; return 1; }
  case "$1" in
    x86_64) _pt_target=x86_64-apple-macos10.9; MACOSX_DEPLOYMENT_TARGET=10.9 ;;
    arm64) _pt_target=arm64-apple-macos11.0; MACOSX_DEPLOYMENT_TARGET=11.0 ;;
  esac
  _pt_want="$(py_pin clang22)"
  if py_host_is_109; then
    CLANG22=/usr/local/mavergreen/clang22
    [ -x "$CLANG22/bin/clang" ] || {
      echo "py_toolchain: no clang22 at $CLANG22; install clang22 $_pt_want" >&2; return 1; }
    _pt_have="$(py_installed_version "$CLANG22")"
    [ "$_pt_have" = "$_pt_want" ] || {
      echo "py_toolchain: the installed clang22 is ${_pt_have:-of unknown version}, but components/clang22/version pins $_pt_want; install clang22 $_pt_want or move the pin" >&2
      return 1; }
  else
    CLANG22="$(py_build_root)/toolchain/clang22-cross-$_pt_want"
    py_fetch_pkg clang22-cross "$_pt_want" "$CLANG22" "mavericks-clang-22-cross-$_pt_want.pkg" || {
      echo "py_toolchain: could not fetch clang22-cross $_pt_want" >&2; return 1; }
  fi
  CLANG22_BIN="$CLANG22/bin"
  if [ "$1" = arm64 ]; then
    SDKROOT="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch arm64)" || return 1
  else
    SDKROOT="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")" || return 1
  fi
  case "$SDKROOT" in
    ''|*' '*|*'	'*) echo "py_toolchain: the SDK path '$SDKROOT' is empty or has a space; CC carries it as one word" >&2; return 1 ;;
  esac
  _pt_flags="--no-default-config --target=$_pt_target -isysroot $SDKROOT -fuse-ld=lld -Wno-unused-command-line-argument"
  CC="$CLANG22_BIN/clang $_pt_flags"
  CXX="$CLANG22_BIN/clang++ $_pt_flags"
  AR="$CLANG22_BIN/llvm-ar"
  RANLIB="$CLANG22_BIN/llvm-ranlib"
  NM="$CLANG22_BIN/llvm-nm"
  export CLANG22 CLANG22_BIN SDKROOT MACOSX_DEPLOYMENT_TARGET CC CXX AR RANLIB NM
  if [ "$1" = x86_64 ]; then
    _pt_rv="$(py_pin recaulk)"
    _pt_rd="$(py_build_root)/toolchain/recaulk-$_pt_rv"
    py_fetch_pkg recaulk "$_pt_rv" "$_pt_rd" || { echo "py_toolchain: could not fetch recaulk $_pt_rv" >&2; return 1; }
    RECAULK_LIB="$_pt_rd/lib/librecaulk.a"
    RECAULK_INCLUDE="$_pt_rd/include/recaulk"
    [ -f "$RECAULK_LIB" ] && [ -d "$RECAULK_INCLUDE" ] || {
      echo "py_toolchain: recaulk $_pt_rv has no lib/librecaulk.a or include/recaulk" >&2; return 1; }
    export RECAULK_LIB RECAULK_INCLUDE
  else
    unset RECAULK_LIB RECAULK_INCLUDE
  fi
}
