#!/bin/sh
# platform: macOS-only -- build-python.sh gets clang22 and Recaulk from pkgs
#   usage: tests/contamination-test.sh
#          Builds every arch this host can (its own, then x86_64 cross from an arm64 host) from a PATH
#          and environment that point at /opt/pkg, and checks each stage. Exits 0 when every arch it
#          could build passed, 77 when it could build none.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/contamination-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $arch: $*"; exit 1; }

mkdir -p "$t/decoy"
cat > "$t/decoy/pkg-config" <<EOF
#!/bin/sh
echo "\$*" >> "$t/decoy-ran"
echo -I/opt/pkg/include
exit 0
EOF
chmod +x "$t/decoy/pkg-config"
arch=decoy
[ "$(PATH="$t/decoy:$PATH" pkg-config --cflags sqlite3)" = -I/opt/pkg/include ] || fail "the decoy pkg-config is not first on PATH"
rm -f "$t/decoy-ran"

foreign_flag_paths() {
  _f_prefix=$1; shift
  : > "$t/foreign"; : > "$t/flagpaths"
  for _f in "$_f_prefix/lib/python3.15/config-3.15-darwin/Makefile" "$_f_prefix"/lib/python3.15/_sysconfigdata_*.py \
      "$_f_prefix"/lib/python3.15/_sysconfig_vars_*.json "$_f_prefix"/lib/pkgconfig/python3.pc \
      "$_f_prefix/bin/python3.15-config"; do
    [ -f "$_f" ] || fail "no $_f to scan"
    grep -o -h -E -- "-(I|L|F|isystem ?|isysroot ?)/[^ '\"\\\\,]*" "$_f" >> "$t/flagpaths" || true
  done
  [ -s "$t/flagpaths" ] || fail "the installed build configuration names no -I or -L path at all; the scan read nothing"
  sed -E 's/^-(I|L|F|isystem ?|isysroot ?)//' "$t/flagpaths" | sort -u | while read -r _f_path; do
    _f_ok=""
    for _f_allowed in "$@"; do
      case "$_f_path" in "$_f_allowed"|"$_f_allowed"/*) _f_ok=1 ;; esac
    done
    [ -n "$_f_ok" ] || printf '%s\n' "$_f_path" >> "$t/foreign"
  done
}

host="$(uname -m)"
case "$host" in x86_64) other=arm64 ;; *) other=x86_64 ;; esac
ran=""; skipped=""; build_python=""
for arch in "$host" "$other"; do
  if ! why="$(py_toolchain_can_build "$arch")"; then
    echo "SKIP $arch: $why"; skipped="$skipped $arch"; continue
  fi
  if [ "$arch" != "$host" ] && [ "$arch" != x86_64 ]; then
    echo "SKIP $arch: only x86_64 cross-builds; $arch builds natively on a $arch Mac"; skipped="$skipped $arch"; continue
  fi
  if [ "$arch" != "$host" ] && [ -z "$build_python" ]; then
    echo "SKIP $arch: a cross build needs the $host build's python3.15"; skipped="$skipped $arch"; continue
  fi
  stage="$t/stage-$arch"
  PATH="$t/decoy:$PATH" PKG_CONFIG=pkg-config PKG_CONFIG_PATH=/opt/pkg/lib/pkgconfig \
    CPPFLAGS=-I/opt/pkg/include CFLAGS=-I/opt/pkg/include LDFLAGS=-L/opt/pkg/lib CPATH=/opt/pkg/include \
    LIBRARY_PATH=/opt/pkg/lib \
    sh "$MAVERICKS_ROOT/build/build-python.sh" --arch "$arch" ${build_python:+--build-python "$build_python"} \
      --stage "$stage" > "$t/$arch.log" 2>&1 || { tail -40 "$t/$arch.log"; fail "build-python.sh exited non-zero"; }
  [ ! -f "$t/decoy-ran" ] || fail "the build ran the decoy pkg-config: $(cat "$t/decoy-ran")"
  prefix="$stage/usr/local/mavergreen/python315"
  [ -x "$prefix/bin/python3.15" ] || fail "no python3.15 in the stage"
  py_toolchain "$arch" > /dev/null
  foreign_flag_paths "$prefix" "$(py_build_root)" "$SDKROOT" "$CLANG22" /usr/local/mavergreen
  [ ! -s "$t/foreign" ] || fail "the installed build configuration (config Makefile, _sysconfigdata, pkgconfig) names host paths: $(tr '\n' ' ' < "$t/foreign")"
  leaks="$(grep -r -l -e /opt/pkg "$stage" || true)"
  [ -z "$leaks" ] || fail "the stage names /opt/pkg in: $leaks"
  grep -r -l -e /usr/local/mavergreen/python315 "$prefix/lib" > /dev/null || fail "the stage scan cannot find even the prefix"
  echo "PASS $arch: built from a PATH whose pkg-config and flags point at /opt/pkg; nothing in the stage names it, and its build configuration names no host path"
  [ "$arch" != "$host" ] || build_python="$prefix/bin/python3.15"
  rc=0; PY_STAGE="$stage" sh "$here/smoke-test.sh" || rc=$?
  case "$rc" in
    0|77) ;;
    *) fail "the smoke test failed on the stage built from the contaminated PATH" ;;
  esac
  ran="$ran $arch"
done
[ -n "$ran" ] || { echo "SKIP: this host could build no arch (reasons above)"; exit 77; }
echo "PASS: contamination (built:$ran${skipped:+; not built here, by design:$skipped})"
