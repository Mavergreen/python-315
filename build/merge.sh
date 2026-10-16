#!/bin/sh
# platform: macOS-only -- lipo-merge-tree.sh lipos the slices; the merged python3.15 compiles the library
#   usage: build/merge.sh --x86_64 STAGE --arm64 STAGE --out STAGE
#          Merges an x86_64 and an arm64 stage from build/build-python.sh into one universal stage at OUT,
#          which must not exist, with shipyard's lipo-merge-tree.sh --require-archs "x86_64 arm64" and
#          clang22's llvm-lipo as lipo. In the merged tree:
#          - include/python3.15/pyconfig.h is build/pyconfig-dispatch.h, which includes the slice's own
#            pyconfig-x86_64.h or pyconfig-arm64.h;
#          - lib/python3.15/_sysconfigdata_*_darwin_darwin.py is build/sysconfigdata-dispatch.py, which
#            loads the slice's own module, renamed <name>_x86_64.py or <name>_arm64.py;
#          - the _sysconfig_vars JSON, build-details.json and config-3.15-darwin/Makefile are
#            <file>.x86_64 and <file>.arm64, with no plain name; lib/python3.15/mavergreen-arch-files.txt
#            lists the plain names, relative to the prefix, for build/link-arch-files.sh;
#          - the library's .pyc files are checked-hash, compiled by the merged python3.15 as make install
#            compiles them; the slices' own are discarded, after checking both have the same ones.
#          Any other non-Mach-O file that differs between the slices fails the merge, naming it.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"

usage() { echo "usage: build/merge.sh --x86_64 STAGE --arm64 STAGE --out STAGE" >&2; exit 2; }
die() { echo "merge: $*" >&2; exit 1; }
x=""; a=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --x86_64) [ "$#" -ge 2 ] || usage; x=$2; shift 2 ;;
    --arm64) [ "$#" -ge 2 ] || usage; a=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$x" ] && [ -n "$a" ] && [ -n "$out" ] || usage
case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac
prefix=/usr/local/mavergreen/python315
ver="$(tr -d '[:space:]' < "$MAVERICKS_ROOT/UPSTREAM_VERSION" | cut -d. -f1,2)"
inc="include/python$ver"
lib="lib/python$ver"
for s in "$x" "$a"; do [ -d "$s$prefix" ] || die "$s has no $prefix"; done
[ ! -e "$out" ] && [ ! -L "$out" ] || die "$out already exists"

sysdata() {
  set -- "$1$prefix/$lib"/_sysconfigdata_*_darwin_darwin.py
  [ "$#" -eq 1 ] && [ -f "$1" ] || die "expected one _sysconfigdata_*_darwin_darwin.py in ${1%/*}, found: $*"
  basename "$1" .py
}
name="$(sysdata "$x")"
[ "$(sysdata "$a")" = "$name" ] || die "the slices name their build-time variables differently: $name, $(sysdata "$a")"
arch_files="$lib/$(printf '%s' "$name" | sed 's/^_sysconfigdata/_sysconfig_vars/').json
$lib/build-details.json
$lib/config-$ver-darwin/Makefile"
for f in $arch_files; do
  for s in "$x" "$a"; do [ -f "$s$prefix/$f" ] || die "$s has no $prefix/$f"; done
done

py_toolchain "$(uname -m)" > /dev/null
mkdir -p "$(py_build_root)"
work="$(mktemp -d "$(py_build_root)/merge.XXXXXX")"
made=""
trap 'rm -rf "$work"; [ -z "$made" ] || rm -rf "$out"' EXIT
mkdir "$work/bin"
ln -s "$CLANG22_BIN/llvm-lipo" "$work/bin/lipo"

cp -Rp "$x" "$work/x86_64.in"
cp -Rp "$a" "$work/arm64.in"
for s in x86_64 arm64; do
  w="$work/$s.in$prefix"
  for h in pyconfig-x86_64.h pyconfig-arm64.h; do [ ! -e "$w/$inc/$h" ] || die "$s already has $inc/$h"; done
  cp "$x$prefix/$inc/pyconfig.h" "$w/$inc/pyconfig-x86_64.h"
  cp "$a$prefix/$inc/pyconfig.h" "$w/$inc/pyconfig-arm64.h"
  cp "$here/pyconfig-dispatch.h" "$w/$inc/pyconfig.h"
  for h in "${name}_x86_64.py" "${name}_arm64.py"; do [ ! -e "$w/$lib/$h" ] || die "$s already has $lib/$h"; done
  cp "$x$prefix/$lib/$name.py" "$w/$lib/${name}_x86_64.py"
  cp "$a$prefix/$lib/$name.py" "$w/$lib/${name}_arm64.py"
  cp "$here/sysconfigdata-dispatch.py" "$w/$lib/$name.py"
  for f in $arch_files; do
    for h in "$f.x86_64" "$f.arm64"; do [ ! -e "$w/$h" ] || die "$s already has $h"; done
    cp "$x$prefix/$f" "$w/$f.x86_64"
    cp "$a$prefix/$f" "$w/$f.arm64"
    rm "$w/$f"
  done
  [ ! -e "$w/$lib/mavergreen-arch-files.txt" ] || die "$s already has $lib/mavergreen-arch-files.txt"
  printf '%s\n' $arch_files > "$w/$lib/mavergreen-arch-files.txt"
  ( cd "$work/$s.in" && find . -name '*.pyc' | sort ) > "$work/$s.pyc"
  find "$work/$s.in" -name __pycache__ -type d -prune -exec rm -rf {} +
done
cmp -s "$work/x86_64.pyc" "$work/arm64.pyc" || {
  diff "$work/x86_64.pyc" "$work/arm64.pyc" | sed -n 's|^< ./|only in x86_64: |p; s|^> ./|only in arm64: |p' >&2
  die "the slices do not compile the same .py files (above)"; }

mkdir -p "$(dirname "$out")"
made=1
PATH="$work/bin:$PATH" sh "$SHIPYARD_SCRIPTS/lipo-merge-tree.sh" --a "$work/x86_64.in" --b "$work/arm64.in" \
  --out "$out" --require-archs "x86_64 arm64" ||
  die "lipo-merge-tree.sh refused (above): only Mach-O, pyconfig.h, $name.py and the files" \
    "mavergreen-arch-files.txt lists may differ between the slices"

compile() {
  env -i HOME="$work" PATH=/usr/bin:/bin "$out$prefix/bin/python$ver" -I -m compileall -q -j0 -o 0 -o 1 -o 2 \
    --invalidation-mode checked-hash -f "$@" > "$work/compileall.log" 2>&1 || {
    tail -20 "$work/compileall.log" >&2; die "the merged python$ver could not compile its library"; }
}
libpl_re="/config-$(printf '%s' "$ver" | sed 's/\./\\./')-darwin/"
compile -d "$prefix/$lib" -x "bad_coding|badsyntax|site-packages|$libpl_re" "$out$prefix/$lib"
compile -d "$prefix/$lib/site-packages" -x badsyntax "$out$prefix/$lib/site-packages"
for s in x86_64 arm64; do
  for o in "" .opt-1 .opt-2; do
    echo "./${prefix#/}/$lib/__pycache__/${name}_$s.cpython-$(printf '%s' "$ver" | tr -d .)$o.pyc" >> "$work/x86_64.pyc"
  done
done
sort -o "$work/x86_64.pyc" "$work/x86_64.pyc"
( cd "$out" && find . -name '*.pyc' | sort ) > "$work/out.pyc"
cmp -s "$work/x86_64.pyc" "$work/out.pyc" || {
  diff "$work/x86_64.pyc" "$work/out.pyc" | sed -n 's|^< ./|not compiled: |p; s|^> ./|compiled but in no slice: |p' >&2
  die "the merged tree's .pyc files are not the slices' (above)"; }
made=""
echo "merge: $x + $a -> $out" >&2
