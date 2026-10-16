#!/bin/sh
# platform: host-agnostic
#   usage: tests/slice-parity-test.sh A_STAGE B_STAGE
#          Compares two build/build-python.sh stages, the slices build/merge.sh makes one tree of. Fails,
#          listing every lib-dynload extension module present in one stage and not the other, and every
#          tests/fixtures/required-modules.txt entry missing from either: one with no source file, package,
#          extension module or built-in (config.c) of its name. Reads files only, never runs either stage,
#          so it holds on any host. Exits 77 with no arguments.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -gt 0 ] || { echo "SKIP: give two stages from build/build-python.sh"; exit 77; }
[ "$#" -eq 2 ] || { echo "usage: tests/slice-parity-test.sh A_STAGE B_STAGE" >&2; exit 2; }
prefix=/usr/local/mavergreen/python315
ver="$(tr -d '[:space:]' < "$here/../UPSTREAM_VERSION" | cut -d. -f1,2)"
lib="lib/python$ver"
t="$(mktemp -d "${TMPDIR:-/tmp}/slice-parity-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
: > "$t/problems"

extension_modules() {
  _d="$1$prefix/$lib/lib-dynload"
  [ -d "$_d" ] || { echo "FAIL: $1 has no $prefix/$lib/lib-dynload" >&2; exit 1; }
  find "$_d" -name '*.so' | sed 's|.*/||; s|\..*||' | sort -u
}
extension_modules "$1" > "$t/a"
extension_modules "$2" > "$t/b"
[ -s "$t/a" ] && [ -s "$t/b" ] || { echo "FAIL: a stage has no extension module at all; the scan read nothing"; exit 1; }
comm -23 "$t/a" "$t/b" | sed "s|^|only in $1: |" >> "$t/problems"
comm -13 "$t/a" "$t/b" | sed "s|^|only in $2: |" >> "$t/problems"

for side in a b; do
  case "$side" in a) s=$1 ;; b) s=$2 ;; esac
  l="$s$prefix/$lib"
  config="$l/config-$ver-darwin/config.c"
  [ -f "$config" ] || { echo "FAIL: $s has no $config, so its built-in modules are unknown"; exit 1; }
  while read -r m; do
    [ -n "$m" ] || continue
    p="$(printf '%s' "$m" | tr . /)"
    [ -f "$l/$p.py" ] || [ -f "$l/$p/__init__.py" ] || grep -q -x -F "$m" "$t/$side" || grep -q -F "{\"$m\"," "$config" ||
      echo "required module $m is missing from $s" >> "$t/problems"
  done < "$here/fixtures/required-modules.txt"
done

if [ -s "$t/problems" ]; then
  cat "$t/problems"
  echo "FAIL: the slices $1 and $2 differ in their modules (above)"
  exit 1
fi
echo "PASS: slice parity: $(wc -l < "$t/a" | tr -d ' ') extension modules in both, and all $(grep -c . "$here/fixtures/required-modules.txt") required modules in each"
