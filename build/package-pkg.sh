#!/bin/sh
# platform: macOS-only -- pkgbuild and productbuild, through shipyard's build_component_pkg.sh and set_install_floor.sh
#   usage: build/package-pkg.sh --stage STAGE --updater-app APP --version V --out DIR
#          Packages the tree at STAGE/usr/local/mavergreen/python315 (from build/build-python.sh, or
#          universal from build/merge.sh) and APP (build/build-updater.sh) as DIR/python-V.pkg: the
#          dev.mavergreen.base component, then the product's, with the 10.9.5 floor and Installer host
#          arches that are python3.15's own. V is the stage's CPython version with its -mavericks.N, and
#          the updater's. The payload leaves out IDLE, tkinter and turtledemo (no Tcl/Tk), and the test
#          suite, which goes to DIR/python-V-tests.tar.gz as ./lib/python3.15/test/ without bytecode, to be
#          unpacked into an installed prefix: entries sorted, owned by root:wheel, dated SOURCE_DATE_EPOCH
#          (default 0), gzip without a name or time, so the same stage gives the same bytes. Both files
#          appear in DIR only once both are made. It adds bin/python, and exports only python, python3 and
#          python3.15. A universal tree's postinstall links its per-arch files for the installing Mac's
#          hardware with libexec/link-arch-files.sh, which it ships. STAGE is not changed.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"

usage() { echo "usage: build/package-pkg.sh --stage STAGE --updater-app APP --version V --out DIR" >&2; exit 2; }
die() { echo "package-pkg: $*" >&2; exit 1; }
stage=""; app=""; V=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage) [ "$#" -ge 2 ] || usage; stage=$2; shift 2 ;;
    --updater-app) [ "$#" -ge 2 ] || usage; app=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; V=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$stage" ] && [ -n "$app" ] && [ -n "$V" ] && [ -n "$out" ] || usage
up="$(tr -d '[:space:]' < "$MAVERICKS_ROOT/UPSTREAM_VERSION")"
ver="$(printf '%s' "$up" | cut -d. -f1,2)"
line="$(printf '%s' "$ver" | tr -d .)"
short="python$line"
prefix="/usr/local/mavergreen/$short"
lib="lib/python$ver"
tree="$stage$prefix"
[ -x "$tree/bin/python$ver" ] || die "$stage has no $prefix/bin/python$ver"
id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" identifier "$short")" || die "$short is not in shipyard's registry"

staged="$(sed -n 's/^#define PY_VERSION[[:space:]]*"\(.*\)"$/\1/p' "$tree/include/python$ver/patchlevel.h")"
case "$V" in
  "$staged"-mavericks.[1-9]*) ;;
  *) die "--version $V is not the stage's CPython ${staged:-(unknown)} with a -mavericks.N" ;;
esac
updv="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)" \
  || die "$app has no Contents/Info.plist with a CFBundleShortVersionString"
[ "$updv" = "$V" ] || die "$app is version $updv, not $V"

py_toolchain "$(uname -m)" > /dev/null
archs_of() { echo $("$CLANG22_BIN/llvm-lipo" -info "$1" | sed -n 's/.*: //p'); }
pyarchs="$(archs_of "$tree/bin/python$ver")"
updarchs="$(archs_of "$app/Contents/MacOS/$short-updater")"
host=""
for a in x86_64 arm64; do
  case " $pyarchs " in *" $a "*) ;; *) continue ;; esac
  case " $updarchs " in *" $a "*) ;; *) die "python$ver is $pyarchs, and the updater has no $a slice ($updarchs)" ;; esac
  host="${host:+$host,}$a"
done
[ -n "$host" ] || die "python$ver is $pyarchs: neither x86_64 nor arm64"
archlist="$tree/$lib/mavergreen-arch-files.txt"
if [ -f "$archlist" ] && [ "$host" != x86_64,arm64 ]; then
  die "$stage lists per-arch files, but python$ver is $pyarchs, not universal"
fi

mkdir -p "$out" "$(py_build_root)"
case "$out" in /*) ;; *) out="$(cd "$out" && pwd)" ;; esac
work="$(mktemp -d "$(py_build_root)/package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
root="$work/root"; dest="$root$prefix"
mkdir -p "${dest%/*}" "$work/scripts" "$work/resources" "$work/component"
COPYFILE_DISABLE=1 cp -Rp "$tree" "$dest"
find "$root" -name '._*' -exec rm -f {} + 2>/dev/null || true

when="${SOURCE_DATE_EPOCH:-0}"
case "$when" in ''|*[!0-9]*) die "SOURCE_DATE_EPOCH is '$when', not a count of seconds" ;; esac
( cd "$dest" && find "$lib/test" -name __pycache__ -prune -o -print | LC_ALL=C sort ) > "$work/tests.list"
{
  echo '#mtree'
  while IFS= read -r f; do
    case "$f" in *[!A-Za-z0-9._/+-]*) die "$f: a test file name this mtree spec cannot carry unescaped" ;; esac
    if [ -d "$dest/$f" ]; then m="type=dir mode=0755"
    elif [ -L "$dest/$f" ] || [ ! -f "$dest/$f" ]; then die "$f is neither a file nor a directory"
    elif [ -x "$dest/$f" ]; then m="type=file mode=0755"
    else m="type=file mode=0644"; fi
    echo "./$f $m uid=0 gid=0 uname=root gname=wheel time=$when.0"
  done < "$work/tests.list"
} > "$work/tests.mtree"
( cd "$dest" && tar -cf - --format ustar "@$work/tests.mtree" ) | gzip -n -9 > "$work/tests.tar.gz"
[ "$(tar -tzf "$work/tests.tar.gz" | wc -l)" -eq "$(wc -l < "$work/tests.list")" ] \
  || die "the tests tarball does not hold the $(wc -l < "$work/tests.list" | tr -d ' ') entries its mtree spec lists"
rm -rf "$dest/bin/idle3" "$dest/bin/idle$ver" "$dest/$lib/idlelib" "$dest/$lib/tkinter" \
  "$dest/$lib/turtledemo" "$dest/$lib/test"
ln -s "python$ver" "$dest/bin/python"
if [ -f "$dest/share/man/man1/python$ver.1" ]; then ln -s "python$ver.1" "$dest/share/man/man1/python.1"; fi

set --
for f in "$dest"/bin/*; do
  case "${f##*/}" in python|python3|"python$ver") ;; *) set -- "$@" --exclude "bin/${f##*/}" ;; esac
done
if [ -f "$archlist" ]; then
  mkdir -p "$dest/libexec"
  cp "$here/link-arch-files.sh" "$dest/libexec/link-arch-files.sh"
  chmod 755 "$dest/libexec/link-arch-files.sh"
  cat > "$work/postinstall-hook" <<EOF
if [ "\$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then _arch=arm64; else _arch=x86_64; fi
sh "\$ROOT$prefix/libexec/link-arch-files.sh" "\$ROOT$prefix" "\$_arch"
EOF
  set -- "$@" --postinstall-hook "$work/postinstall-hook"
fi
sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$root" --product "$short" --name "Python $ver" \
  --group python --line "$line" --version "$V" --updater-app "$app" --scripts-out "$work/scripts" "$@" >&2
find "$root" -name '._*' -exec rm -f {} + 2>/dev/null || true

cp "$MAVERICKS_ROOT/scripts/resources/Welcome.html" "$work/resources/"
cp "$dest/$lib/LICENSE.txt" "$work/resources/LICENSE.txt"
comp="$work/component/$short.pkg"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$root" --identifier "$id" --version "$V" \
  --install-location / --scripts "$work/scripts" --out "$comp" >&2
sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "$id" --title "Mavericks Python $ver" \
  --component "$comp" --out "$work/product.pkg" --resources "$work/resources" --welcome Welcome.html \
  --license LICENSE.txt --host-arch "$host" --min-os 10.9.5 --require-scripts >&2
pkg="$out/python-$V.pkg"; tests="$out/python-$V-tests.tar.gz"
mv "$work/product.pkg" "$pkg"
mv "$work/tests.tar.gz" "$tests"
echo "package-pkg: $pkg ($host) and $tests" >&2
