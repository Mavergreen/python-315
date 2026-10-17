#!/bin/sh
# platform: macOS-only -- build/package-pkg.sh runs pkgbuild and productbuild, and pkgutil expands the result
#   usage: [PY_STAGE=DIR [PY_UPDATER_APP=APP]] tests/package-manifest-test.sh
#          Packages a tiny universal stand-in stage with build/package-pkg.sh, expands the pkg and runs its
#          postinstall against a scratch volume: the components, Distribution, payload, manifest, farm
#          links, per-arch links and the test-suite tarball are what the family and this product expect.
#          With PY_STAGE (a stage from build/build-python.sh or build/merge.sh) it also packages that,
#          with PY_UPDATER_APP or an updater build/build-updater.sh builds for this host, runs shipyard's
#          artifact conformance over it, and runs the expanded python.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
package="$MAVERICKS_ROOT/build/package-pkg.sh"
prefix=/usr/local/mavergreen/python315
up="$(tr -d '[:space:]' < "$MAVERICKS_ROOT/UPSTREAM_VERSION")"
ver="$(printf '%s' "$up" | cut -d. -f1,2)"
nodot="$(printf '%s' "$ver" | tr -d .)"
short="python$nodot"
lib="lib/python$ver"
V="$up-mavericks.7"
id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" identifier "$short")"
upd_id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" updater-bundle-id "$short")"
feed="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" feed "$short")"
upd_rel="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" updater-app "$short")"
label="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" agent-label "$short")"
py_toolchain "$(uname -m)" > /dev/null
mkdir -p "$(py_build_root)"
t="$(mktemp -d "$(py_build_root)/package-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }
PB=/usr/libexec/PlistBuddy

printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$t/x86_64-header"
printf '\317\372\355\376\014\000\000\001\000\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$t/arm64-header"
"$CLANG22_BIN/llvm-lipo" -create "$t/x86_64-header" "$t/arm64-header" -output "$t/fat"
chmod +x "$t/fat"
[ "$(echo $("$CLANG22_BIN/llvm-lipo" -info "$t/fat" | sed -n 's/.*: //p'))" = "x86_64 arm64" ] || fail "the stand-in Mach-O is not x86_64 and arm64"

tiny_stage() {
  s="$1$prefix"
  mkdir -p "$s/bin" "$s/include/python$ver" "$s/$lib/test/__pycache__" "$s/$lib/idlelib" "$s/$lib/tkinter" \
    "$s/$lib/turtledemo" "$s/$lib/config-$ver-darwin" "$s/$lib/site-packages" "$s/share/man/man1"
  cp "$t/fat" "$s/bin/python$ver"
  ln -s "python$ver" "$s/bin/python3"
  for f in idle3 "idle$ver" pydoc3 "pydoc$ver" "python$ver-config"; do printf '#!/bin/sh\n' > "$s/bin/$f"; done
  ln -s "python$ver-config" "$s/bin/python3-config"
  printf '#define PY_VERSION              "%s"\n' "$up" > "$s/include/python$ver/patchlevel.h"
  printf 'PSF license\n' > "$s/$lib/LICENSE.txt"
  printf 'import os\n' > "$s/$lib/os.py"
  printf 'x = 1\n' > "$s/$lib/test/test_tiny.py"
  printf 'a\n' > "$s/$lib/test/alpha.txt"
  printf 'Z\n' > "$s/$lib/test/Zeta.txt"
  printf 'pyc\n' > "$s/$lib/test/__pycache__/test_tiny.cpython-$nodot.pyc"
  for d in idlelib tkinter turtledemo; do printf '\n' > "$s/$lib/$d/__init__.py"; done
  printf 'python3.15(1)\n' > "$s/share/man/man1/python$ver.1"
  ln -s "python$ver.1" "$s/share/man/man1/python3.1"
  printf '%s\n' "$lib/_sysconfig_vars__darwin_darwin.json" "$lib/build-details.json" \
    "$lib/config-$ver-darwin/Makefile" > "$s/$lib/mavergreen-arch-files.txt"
  for a in x86_64 arm64; do
    printf '{"arch": "%s"}\n' "$a" > "$s/$lib/_sysconfig_vars__darwin_darwin.json.$a"
    printf '{"platform": "%s"}\n' "$a" > "$s/$lib/build-details.json.$a"
    printf 'ARCH=%s\n' "$a" > "$s/$lib/config-$ver-darwin/Makefile.$a"
  done
}

tiny_updater() {
  a="$1/$short-updater.app/Contents"
  mkdir -p "$a/MacOS"
  cp "$t/fat" "$a/MacOS/$short-updater"
  cat > "$a/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$upd_id</string>
<key>CFBundleExecutable</key><string>$short-updater</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>SUFeedURL</key><string>$feed</string>
</dict></plist>
EOF
}

expand() {
  rm -rf "$t/x" "$t/root" "$t/scripts"
  pkgutil --expand "$1" "$t/x" || fail "pkgutil could not expand $1"
  mkdir -p "$t/root" "$t/scripts"
  for c in "$t/x"/*.pkg; do
    tar -xf "$c/Payload" -C "$t/root" || fail "could not read $c/Payload"
  done
  for c in "$t/x"/*.pkg; do
    if [ "$(sed -n 's/.*<pkg-info[^>]* identifier="\([^"]*\)".*/\1/p' "$c/PackageInfo")" = "$id" ]; then
      cp -R "$c/Scripts/." "$t/scripts/"
    fi
  done
  [ -x "$t/scripts/postinstall" ] || fail "the $id component has no postinstall"
}

check_pkg() {
  pkg="$1"; host_archs="$2"; arm64_hw="$3"; tests="$4"; dist="$t/x/Distribution"
  comps="$(sed -n 's/.*<pkg-ref id="\([^"]*\)".*/\1/p' "$dist" | awk '!seen[$0]++' | tr '\n' ' ')"
  [ "$comps" = "dev.mavergreen.base $id " ] || fail "components are '$comps', not dev.mavergreen.base then $id"
  grep -q "hostArchitectures=\"$host_archs\"" "$dist" || fail "Distribution does not declare hostArchitectures=\"$host_archs\": $(grep hostArch "$dist")"
  grep -q '<title>Mavericks Python '"$ver"'</title>' "$dist" || fail "Distribution's title is not Mavericks Python $ver"
  grep -q '<os-version[^>]*min="10\.9\.5"' "$dist" || fail "Distribution declares no 10.9.5 floor: $(grep os-version "$dist")"
  grep -q '<license file="LICENSE.txt"' "$dist" || fail "Distribution shows no license"
  grep -q '<welcome file="Welcome.html"' "$dist" || fail "Distribution shows no welcome"

  ( cd "$t/root" && find . \( -type f -o -type l \) | sed 's|^\./||' ) > "$t/files"
  stray="$(grep -v -e "^usr/local/mavergreen/$short/" -e "^$upd_rel/" -e "^Library/LaunchAgents/$label\.plist$" \
    -e '^usr/local/mavergreen/\.base/' "$t/files" || true)"
  [ -z "$stray" ] || fail "the payload installs outside $prefix and the updater: $stray"
  grep -q "^$upd_rel/Contents/Info.plist$" "$t/files" || fail "the payload has no $upd_rel"
  m="$t/root$prefix/mavergreen.plist"
  [ "$("$PB" -c 'Print :identifier' "$m")" = "$id" ] || fail "manifest identifier is not $id"
  [ "$("$PB" -c 'Print :product' "$m")" = "$short" ] || fail "manifest product is not $short"
  [ "$("$PB" -c 'Print :group' "$m")" = python ] || fail "manifest group is not python"
  [ "$("$PB" -c 'Print :line' "$m")" = "$nodot" ] || fail "manifest line is not $nodot"
  [ "$("$PB" -c 'Print :version' "$m")" = "$V" ] || fail "manifest version is not $V"
  [ "$("$PB" -c 'Print :appcast' "$m")" = "$feed" ] || fail "manifest appcast is not $feed"
  for p in "bin/idle3" "bin/idle$ver" "$lib/idlelib" "$lib/tkinter" "$lib/turtledemo" "$lib/test"; do
    [ ! -e "$t/root$prefix/$p" ] && [ ! -L "$t/root$prefix/$p" ] || fail "the payload ships $p, which phase 1 prunes"
  done
  ls "$t/root$prefix/bin" | grep -q '^pip' && fail "the payload ships a pip: $(ls "$t/root$prefix/bin")"
  [ "$(readlink "$t/root$prefix/bin/python")" = "python$ver" ] || fail "bin/python does not link to python$ver"

  mkdir -p "$t/fakebin"
  printf '#!/bin/sh\necho %s\n' "$arm64_hw" > "$t/fakebin/sysctl"; chmod +x "$t/fakebin/sysctl"
  PATH="$t/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "$t/scripts/postinstall" "$pkg" / "$t/root" > "$t/post.out" 2>&1 \
    || fail "postinstall failed: $(cat "$t/post.out")"
  got="$(ls "$t/root/usr/local/mavergreen/bin" | tr '\n' ' ')"
  [ "$got" = "python python-$nodot python3 python3-$nodot python$ver python$ver-$nodot " ] \
    || fail "the farm exports '$got', not python, python3 and python$ver, bare and as -$nodot"
  [ "$(cat "$t/root/usr/local/mavergreen/var/mavergreen/selections/python")" = "$short" ] \
    || fail "installing the only member did not select it"
  tar -tzf "$tests" > "$t/tests-list" || fail "cannot list $tests"
  grep -qx "\./$lib/test/" "$t/tests-list" || fail "$tests lacks ./$lib/test/: $(head -3 "$t/tests-list")"
  grep -v "^\./$lib/test/" "$t/tests-list" | grep -q . && fail "$tests carries more than ./$lib/test/: $(grep -v "^\./$lib/test/" "$t/tests-list" | head -3)"
  sed 's|/$||' "$t/tests-list" | LC_ALL=C sort -c || fail "$tests is not in sorted order"
  tar -tvzf "$tests" | awk '$3 != "root" || $4 != "wheel" { print; exit 1 }' > "$t/o" \
    || fail "$tests has an entry not owned by root:wheel: $(cat "$t/o")"
  grep -q __pycache__ "$t/tests-list" && fail "$tests carries bytecode"
  :
}

mkdir -p "$t/tiny" "$t/upd" "$t/out"
tiny_stage "$t/tiny"
tiny_updater "$t/upd" "$up-mavericks.6"
if sh "$package" --stage "$t/tiny" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg took an updater at another version"
fi
grep -q "$up-mavericks.6" "$t/o" || fail "the version refusal does not name the updater's version: $(cat "$t/o")"
rm -rf "$t/upd"; mkdir "$t/upd"; tiny_updater "$t/upd" "3.14.9-mavericks.1"
if sh "$package" --stage "$t/tiny" --updater-app "$t/upd/$short-updater.app" --version "3.14.9-mavericks.1" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg took a version that is not the stage's"
fi
grep -q "not the stage's CPython $up" "$t/o" || fail "the version refusal does not name the stage's version: $(cat "$t/o")"
rm -rf "$t/upd"; mkdir "$t/upd"; tiny_updater "$t/upd" "$V"
cp "$t/x86_64-header" "$t/upd/$short-updater.app/Contents/MacOS/$short-updater"
if sh "$package" --stage "$t/tiny" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg took an x86_64 updater for a universal python"
fi
grep -q 'no arm64 slice' "$t/o" || fail "the arch refusal does not name the missing slice: $(cat "$t/o")"
cp "$t/fat" "$t/upd/$short-updater.app/Contents/MacOS/$short-updater"
sh "$package" --stage "$t/tiny" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out" > "$t/o" 2>&1 \
  || fail "package-pkg failed on the tiny stage: $(cat "$t/o")"
pkg="$t/out/python-$V.pkg"; tests="$t/out/python-$V-tests.tar.gz"
[ -f "$pkg" ] || fail "no $pkg: $(ls "$t/out")"
find "$t/tiny$prefix/$lib/test" -exec touch -t 202001020304 {} +
mkdir "$t/out2"
sh "$package" --stage "$t/tiny" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out2" > "$t/o" 2>&1 \
  || fail "package-pkg failed the second time: $(cat "$t/o")"
cmp -s "$tests" "$t/out2/python-$V-tests.tar.gz" \
  || fail "the tests tarball differs between two packagings of one stage whose test files' mtimes moved"
mv "$t/tiny$prefix/$lib/LICENSE.txt" "$t/LICENSE.txt"
mkdir "$t/out3"
if sh "$package" --stage "$t/tiny" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out3" > "$t/o" 2>&1; then
  fail "package-pkg succeeded with no LICENSE.txt"
fi
[ -z "$(ls "$t/out3")" ] || fail "a failed packaging left $(ls "$t/out3") behind"
mv "$t/LICENSE.txt" "$t/tiny$prefix/$lib/LICENSE.txt"
[ -d "$t/tiny$prefix/$lib/idlelib" ] || fail "package-pkg pruned the caller's stage"
expand "$pkg"
check_pkg "$pkg" "x86_64,arm64" 1 "$tests"
grep -qx "\./$lib/test/test_tiny.py" "$t/tests-list" || fail "$tests lacks $lib/test/test_tiny.py: $(cat "$t/tests-list")"
for f in _sysconfig_vars__darwin_darwin.json build-details.json "config-$ver-darwin/Makefile"; do
  [ "$(readlink "$t/root$prefix/$lib/$f")" = "${f##*/}.arm64" ] || fail "on arm64 hardware $f links to $(readlink "$t/root$prefix/$lib/$f")"
done
printf '#!/bin/sh\necho 0\n' > "$t/fakebin/sysctl"
PATH="$t/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "$t/scripts/postinstall" "$pkg" / "$t/root" > "$t/post.out" 2>&1 \
  || fail "postinstall failed on Intel: $(cat "$t/post.out")"
grep -q ARCH=x86_64 "$t/root$prefix/$lib/config-$ver-darwin/Makefile" || fail "on Intel hardware the Makefile is not x86_64's"
printf '#!/bin/sh\nexit 1\n' > "$t/fakebin/sysctl"
PATH="$t/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" "$t/scripts/postinstall" "$pkg" / "$t/root" > "$t/post.out" 2>&1 \
  || fail "postinstall failed where hw.optional.arm64 does not exist: $(cat "$t/post.out")"
grep -q x86_64 "$t/root$prefix/$lib/build-details.json" || fail "where hw.optional.arm64 does not exist, build-details.json is not x86_64's"
echo "PASS tiny stage: base then $id, both arches, the 10.9.5 floor; the payload is $prefix and its updater, without IDLE, tkinter, turtledemo, the tests or pip; the manifest, the farm's python, python3 and python$ver, the per-arch files linked by hardware; the tests ship apart, the same bytes from each packaging, and a failed packaging leaves nothing"

if [ -z "${PY_STAGE:-}" ]; then
  echo "PASS: package (ran: tiny stage; not run here: a real stage, which needs PY_STAGE)"
  exit 0
fi
[ -d "$PY_STAGE$prefix" ] || fail "PY_STAGE has no $prefix"
app="${PY_UPDATER_APP:-}"
if [ -z "$app" ]; then
  app="$t/real-upd/$short-updater.app"
  sh "$MAVERICKS_ROOT/build/build-updater.sh" --arch "$(uname -m)" --out "$app" > "$t/o" 2>&1 \
    || fail "build-updater failed: $(cat "$t/o")"
fi
RV="$("$PB" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
mkdir -p "$t/dist"
sh "$package" --stage "$PY_STAGE" --updater-app "$app" --version "$RV" --out "$t/dist" > "$t/o" 2>&1 \
  || fail "package-pkg failed on $PY_STAGE: $(cat "$t/o")"
V="$RV"
pkg="$t/dist/python-$V.pkg"; tests="$t/dist/python-$V-tests.tar.gz"
archs="$(echo $("$CLANG22_BIN/llvm-lipo" -info "$PY_STAGE$prefix/bin/python$ver" | sed -n 's/.*: //p'))"
hw="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
if [ "$hw" = 1 ]; then hwarch=arm64; else hw=0; hwarch=x86_64; fi
expand "$pkg"
check_pkg "$pkg" "$(printf '%s' "$archs" | tr ' ' ',')" "$hw" "$tests"
grep -qx "\./$lib/test/test_grammar.py" "$t/tests-list" || fail "$tests lacks the real suite's test_grammar.py"
if [ -f "$PY_STAGE$prefix/$lib/mavergreen-arch-files.txt" ]; then
  while IFS= read -r f || [ -n "$f" ]; do
    [ "$(readlink "$t/root$prefix/$f")" = "${f##*/}.$hwarch" ] \
      || fail "on this $hwarch hardware $f links to '$(readlink "$t/root$prefix/$f")', not ${f##*/}.$hwarch"
  done < "$PY_STAGE$prefix/$lib/mavergreen-arch-files.txt"
else
  [ -f "$t/root$prefix/$lib/build-details.json" ] && [ ! -L "$t/root$prefix/$lib/build-details.json" ] \
    || fail "a single-arch tree lost its own build-details.json"
fi
case " $archs " in
  *" $(uname -m) "*)
    out="$("$t/root/usr/local/mavergreen/bin/python3-$nodot" -c 'import sqlite3, lzma, ctypes, sys
try:
    import tkinter
except ModuleNotFoundError as e:
    print(e.name)
try:
    import test
except ModuleNotFoundError as e:
    print(e.name)
print(sys.prefix)')" || fail "the expanded python3-$nodot did not run"
    [ "$out" = "tkinter
test
$t/root$prefix" ] || fail "the expanded python reported: $out" ;;
esac
sh "$SHIPYARD_SCRIPTS/stand-in-feeds.sh" "$t/dist" "$V" > "$t/o" 2>&1 || fail "stand-in-feeds failed: $(cat "$t/o")"
facts="$(sh "$SHIPYARD_SCRIPTS/artifact-facts.sh" "$t/dist" "$V" "$MAVERICKS_ROOT")" || fail "artifact-facts failed"
printf '%s\n' "$facts" | sh "$SHIPYARD_SCRIPTS/check-artifact-conformance.sh" > "$t/o" 2>&1 \
  || fail "conformance: $(cat "$t/o")"
echo "PASS real stage ($archs, on $hwarch hardware): the same, conformance ($(tail -1 "$t/o")), and the expanded python runs without tkinter or the tests"
echo "PASS: package (ran: tiny stage, real stage)"
