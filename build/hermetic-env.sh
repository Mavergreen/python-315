# platform: host-agnostic
#   usage: . build/hermetic-env.sh; py_toolchain ARCH; py_hermetic CMD [ARG...]
#          Runs CMD with an empty environment except HOME (a fresh empty directory under the build root, so
#          no user site-packages or dotfile reaches a build), TMPDIR, PATH (clang22's bin, then
#          /usr/bin:/bin:/usr/sbin:/sbin), PKG_CONFIG=/usr/bin/false, PKG_CONFIG_LIBDIR=/nonexistent, and
#          py_toolchain's SDKROOT and MACOSX_DEPLOYMENT_TARGET. Returns 1 if py_toolchain has not run.
#          Needs build/toolchain.sh sourced first.
py_hermetic() {
  [ -n "${CLANG22_BIN:-}" ] && [ -n "${SDKROOT:-}" ] && [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ] || {
    echo "py_hermetic: no toolchain; run py_toolchain ARCH first" >&2; return 1; }
  mkdir -p "$(py_build_root)" || return 1
  _ph_home="$(mktemp -d "$(py_build_root)/home.XXXXXX")" || return 1
  _ph_rc=0
  env -i HOME="$_ph_home" TMPDIR="${TMPDIR:-/tmp}" \
    PATH="$CLANG22_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PKG_CONFIG=/usr/bin/false PKG_CONFIG_LIBDIR=/nonexistent \
    SDKROOT="$SDKROOT" MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" "$@" || _ph_rc=$?
  rm -rf "$_ph_home"
  return "$_ph_rc"
}
