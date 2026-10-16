#!/bin/sh
# platform: macOS-only -- merge.sh runs lipo-merge-tree.sh, and the checks compile pyconfig.h with clang22
#   usage: [PY_STAGE=DIR] tests/merge-test.sh
#          Checks tests/slice-parity-test.sh, build/merge.sh and build/link-arch-files.sh on synthetic
#          stages. Tiny trees, whose python3.15 is a stand-in that only writes .pyc names, need no build;
#          the rest need PY_STAGE, an x86_64 stage from build/build-python.sh, whose copy stands in for the
#          arm64 slice with its Mach-O replaced by arm64 headers. Exits 77 after the tiny cases when
#          PY_STAGE is unset.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
parity="$here/slice-parity-test.sh"
merge="$MAVERICKS_ROOT/build/merge.sh"
link="$MAVERICKS_ROOT/build/link-arch-files.sh"
prefix=/usr/local/mavergreen/python315
ver="$(tr -d '[:space:]' < "$MAVERICKS_ROOT/UPSTREAM_VERSION" | cut -d. -f1,2)"
nodot="$(printf '%s' "$ver" | tr -d .)"
lib="lib/python$ver"
inc="include/python$ver"
sysdata=_sysconfigdata__darwin_darwin
arch_files="$lib/_sysconfig_vars__darwin_darwin.json
$lib/build-details.json
$lib/config-$ver-darwin/Makefile"
mkdir -p "$(py_build_root)"
t="$(mktemp -d "$(py_build_root)/merge-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }
says() { grep -q -F -e "$1" "$t/out" || fail "$2: wanted \"$1\" in: $(cat "$t/out")"; }

tiny() {
  _r="$1$prefix"; _l="$_r/$lib"
  mkdir -p "$_r/bin" "$_r/$inc" "$_l/lib-dynload" "$_l/config-$ver-darwin" "$_l/site-packages"
  printf '#define TINY_SLICE 1\n' > "$_r/$inc/pyconfig.h"
  printf 'build_time_vars = {}\n' > "$_l/$sysdata.py"
  for _f in $arch_files; do printf 'x86_64 %s\n' "$_f" > "$_r/$_f"; done
  cat > "$_r/bin/python$ver" <<EOF
#!/bin/sh
for d; do :; done
find "\$d" -name '*.py' | while read -r f; do
  b="\${f##*/}"; c="\${f%/*}/__pycache__"; mkdir -p "\$c"
  for o in "" .opt-1 .opt-2; do : > "\$c/\${b%.py}.cpython-$nodot\$o.pyc"; done
done
EOF
  chmod +x "$_r/bin/python$ver"
  printf 'struct _inittab _PyImport_Inittab[] = {\n    {"zlib", PyInit_zlib},\n};\n' > "$_l/config-$ver-darwin/config.c"
  for _so in _scproxy _json readline pyexpat _decimal; do
    : > "$_l/lib-dynload/$_so.cpython-$nodot-darwin.so"
  done
  while read -r _m; do
    _p="$(printf '%s' "$_m" | tr . /)"
    case "$_m" in
      ''|zlib|readline|pyexpat|_decimal) ;;
      sqlite3|ctypes|zoneinfo|compression.zstd) mkdir -p "$_l/$_p"; : > "$_l/$_p/__init__.py" ;;
      *) mkdir -p "$(dirname "$_l/$_p")"; : > "$_l/$_p.py" ;;
    esac
  done < "$here/fixtures/required-modules.txt"
  "$_r/bin/python$ver" -m compileall "$_l"
}

rc=0; sh "$parity" > "$t/out" 2>&1 || rc=$?
[ "$rc" = 77 ] || fail "slice-parity-test.sh with no stages exited $rc, not 77"

tiny "$t/a"
cp -Rp "$t/a" "$t/b"
sh "$parity" "$t/a" "$t/b" > "$t/out" 2>&1 || fail "parity of two identical tiny stages: $(cat "$t/out")"
says "PASS" "parity of two identical tiny stages"

rm "$t/b$prefix/$lib/lib-dynload/_scproxy.cpython-$nodot-darwin.so"
if sh "$parity" "$t/a" "$t/b" > "$t/out" 2>&1; then fail "parity passed with _scproxy in one stage only"; fi
says "only in $t/a: _scproxy" "a module in one stage only"

rm "$t/b$prefix/$lib/lib-dynload/readline.cpython-$nodot-darwin.so" "$t/a$prefix/$lib/lib-dynload/readline.cpython-$nodot-darwin.so"
rm "$t/b$prefix/$lib/lib-dynload/_decimal.cpython-$nodot-darwin.so"
rm "$t/a$prefix/$lib/lzma.py"
rm -r "$t/a$prefix/$lib/compression/zstd"
sed 's/"zlib"/"zlibx"/' "$t/a$prefix/$lib/config-$ver-darwin/config.c" > "$t/config.c"
cat "$t/config.c" > "$t/a$prefix/$lib/config-$ver-darwin/config.c"
if sh "$parity" "$t/a" "$t/b" > "$t/out" 2>&1; then fail "parity passed with required modules missing"; fi
says "only in $t/a: _scproxy" "a module in one stage only, beside missing required modules"
says "required module readline is missing from $t/a" "a required extension module missing"
says "required module readline is missing from $t/b" "a required extension module missing from both"
says "required module lzma is missing from $t/a" "a required source module missing"
says "required module compression.zstd is missing from $t/a" "a required package missing"
says "required module zlib is missing from $t/a" "a required built-in missing"
says "only in $t/a: _decimal" "a required extension module in one stage only"
says "required module _decimal is missing from $t/b" "a required extension module in one stage only"
if grep -q -e "lzma is missing from $t/b" -e "zstd is missing from $t/b" -e "zlib is missing from $t/b" "$t/out"; then
  fail "parity blamed $t/b for a module only $t/a lacks: $(cat "$t/out")"; fi

rm -rf "$t/a" "$t/b"
tiny "$t/x"; tiny "$t/r"
printf '#define TINY_ARM64 1\n' > "$t/r$prefix/$inc/pyconfig.h"
printf 'build_time_vars = {"MACOSX_DEPLOYMENT_TARGET": "11.0"}\n' > "$t/r$prefix/$lib/$sysdata.py"
for f in $arch_files; do printf 'arm64 %s\n' "$f" > "$t/r$prefix/$f"; done
cp -Rp "$t/r" "$t/r2"
printf '/* arm64 */\n' >> "$t/r2$prefix/$lib/config-$ver-darwin/config.c"
if sh "$merge" --x86_64 "$t/x" --arm64 "$t/r2" --out "$t/out-stage" > "$t/out" 2>&1; then
  fail "merge passed with config.c, which no list names, differing between the slices"; fi
grep "$lib/config-$ver-darwin/config.c differs" "$t/out" | grep -q refus ||
  fail "an unlisted differing file: wanted the merge to refuse $lib/config-$ver-darwin/config.c in: $(cat "$t/out")"
if grep -q -e "pyconfig.h differs" -e "$sysdata.py differs" -e "json differs" -e "Makefile differs" "$t/out"; then
  fail "the merge refused a file it dispatches or keeps per arch: $(cat "$t/out")"; fi
[ ! -e "$t/out-stage" ] || fail "a refused merge left $t/out-stage behind"

sh "$merge" --x86_64 "$t/x" --arm64 "$t/r" --out "$t/out-stage" > "$t/out" 2>&1 ||
  fail "merge of tiny slices differing in pyconfig.h, $sysdata.py and the per-arch files: $(cat "$t/out")"
m="$t/out-stage$prefix"
for f in $arch_files; do
  [ ! -e "$m/$f" ] && [ ! -L "$m/$f" ] || fail "the merged tree has a plain $f"
  cmp -s "$m/$f.x86_64" "$t/x$prefix/$f" || fail "$f.x86_64 is not the x86_64 slice's $f"
  cmp -s "$m/$f.arm64" "$t/r$prefix/$f" || fail "$f.arm64 is not the arm64 slice's $f"
done
printf '%s\n' $arch_files | sort > "$t/want"
sort "$m/$lib/mavergreen-arch-files.txt" > "$t/got"
cmp -s "$t/want" "$t/got" || fail "mavergreen-arch-files.txt lists: $(cat "$m/$lib/mavergreen-arch-files.txt")"

linked() {
  for _f in $arch_files; do
    [ -L "$m/$_f" ] || fail "$2: $_f is not a symlink"
    [ "$(readlink "$m/$_f")" = "${_f##*/}.$1" ] || fail "$2: $_f links to $(readlink "$m/$_f"), not ${_f##*/}.$1"
    cmp -s "$m/$_f" "$3$prefix/$_f" || fail "$2: $_f does not read as the $1 slice's"
  done
}
sh "$link" "$m" x86_64 > "$t/out" 2>&1 || fail "link-arch-files.sh x86_64: $(cat "$t/out")"
linked x86_64 "linked for x86_64" "$t/x"
sh "$link" "$m" x86_64 > "$t/out" 2>&1 || fail "link-arch-files.sh x86_64 again: $(cat "$t/out")"
linked x86_64 "linked for x86_64 twice" "$t/x"
sh "$link" "$m" arm64 > "$t/out" 2>&1 || fail "link-arch-files.sh arm64 over x86_64's links: $(cat "$t/out")"
linked arm64 "relinked for arm64" "$t/r"
rm -f "$t/out-stage$prefix/$lib/build-details.json"
printf 'a real file\n' > "$m/$lib/build-details.json"
if sh "$link" "$m" x86_64 > "$t/out" 2>&1; then fail "link-arch-files.sh replaced a real file"; fi
says "not a symlink" "a plain name that is a real file"
[ "$(cat "$m/$lib/build-details.json")" = "a real file" ] || fail "link-arch-files.sh changed the real file it refused"
[ "$(readlink "$m/$lib/config-$ver-darwin/Makefile")" = Makefile.arm64 ] || fail "a refused link-arch-files.sh changed another link"
rm -f "$t/out-stage$prefix/$lib/build-details.json"
ln -s build-details.json.arm64 "$m/$lib/build-details.json"
mv "$m/$lib/build-details.json.x86_64" "$t/held"
if sh "$link" "$m" x86_64 > "$t/out" 2>&1; then fail "link-arch-files.sh linked to a missing x86_64 copy"; fi
says "no $m/$lib/build-details.json.x86_64" "a missing arch copy"
linked arm64 "after a refused relink" "$t/r"
mv "$t/held" "$m/$lib/build-details.json.x86_64"
rc=0; sh "$link" "$m" ppc > "$t/out" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "link-arch-files.sh ppc exited $rc, not 2"
printf '%s' "$(cat "$m/$lib/mavergreen-arch-files.txt")" > "$t/unterminated"
cat "$t/unterminated" > "$m/$lib/mavergreen-arch-files.txt"
[ "$(tail -c 1 "$m/$lib/mavergreen-arch-files.txt")" = e ] || fail "the list still ends in a newline"
sh "$link" "$m" x86_64 > "$t/out" 2>&1 || fail "link-arch-files.sh on a list with no final newline: $(cat "$t/out")"
linked x86_64 "a list whose last line has no newline" "$t/x"
rm -rf "$t/out-stage"

cp -Rp "$t/x" "$t/x2"
: > "$t/x2$prefix/$lib/${sysdata}_arm64.py"
if sh "$merge" --x86_64 "$t/x2" --arm64 "$t/r" --out "$t/out-stage" > "$t/out" 2>&1; then
  fail "merge took a slice that already has ${sysdata}_arm64.py"; fi
says "already has $lib/${sysdata}_arm64.py" "a slice with a per-arch sysconfigdata module"
rm -rf "$t/x2"

mkdir "$t/e1" "$t/e2"
rc=0; sh "$parity" "$t/e1" "$t/e2" > "$t/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "slice-parity-test.sh on two empty stages exited $rc, not 1"
says "has no $prefix/$lib/lib-dynload" "a stage with no lib-dynload"

rm "$t/r$prefix/$lib/lib-dynload/_scproxy.cpython-$nodot-darwin.so"
if sh "$merge" --x86_64 "$t/x" --arm64 "$t/r" --out "$t/out-stage" > "$t/out" 2>&1; then
  fail "merge passed with _scproxy in one slice only"; fi
says "_scproxy" "a module in one slice only"
[ ! -e "$t/out-stage" ] || fail "a refused merge left $t/out-stage behind"

mkdir "$t/out-stage"
if sh "$merge" --x86_64 "$t/x" --arm64 "$t/x" --out "$t/out-stage" > "$t/out" 2>&1; then
  fail "merge wrote over an existing --out"; fi
says "already exists" "an existing --out"
[ -d "$t/out-stage" ] || fail "a refused merge removed an --out it did not make"
rmdir "$t/out-stage"
if sh "$merge" --x86_64 "$t/x" --arm64 "$t" --out "$t/out-stage" > "$t/out" 2>&1; then
  fail "merge took a stage with no $prefix"; fi
says "no $prefix" "a stage with no tree"
echo "PASS tiny stages: slice parity names a module in one slice and each missing required module; merge keeps the per-arch files as <file>.<arch> and lists them, and refuses an unlisted differing file, a module in one slice, an existing --out; link-arch-files.sh links either arch, again, and refuses a real file or a missing copy"

[ -n "${PY_STAGE:-}" ] || {
  echo "PASS: merge (ran: tiny stages; not run here: real stages, which need PY_STAGE, an x86_64 stage from build/build-python.sh)"
  exit 0; }
[ -x "$PY_STAGE$prefix/bin/python3.15" ] || fail "no $PY_STAGE$prefix/bin/python3.15"
py_toolchain x86_64 > /dev/null
B="$CLANG22_BIN"

x="$t/x86_64"; a="$t/arm64"; o="$t/merged"
rm -rf "$t/x" "$t/r"
cp -Rp "$PY_STAGE" "$x"
rm -rf "${x:?}$prefix/$lib/test"
cp -Rp "$x" "$a"
printf '\317\372\355\376\014\000\000\001\000\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$t/arm64-header"
"$B/llvm-lipo" -info "$t/arm64-header" | grep -q 'architecture: arm64' || fail "the arm64 stand-in is not an arm64 Mach-O to llvm-lipo"
find "$a" -type f -exec /usr/bin/file {} + | sed -n 's/: *Mach-O.*//p' > "$t/machos"
[ -s "$t/machos" ] || fail "no Mach-O in the stage copy"
while read -r f; do cat "$t/arm64-header" > "$f"; done < "$t/machos"
printf '#define PY315_TEST_ARM64_SLICE 1\n' >> "$a$prefix/$inc/pyconfig.h"
sed "s/'MACOSX_DEPLOYMENT_TARGET': '10.9'/'MACOSX_DEPLOYMENT_TARGET': '11.0'/" "$x$prefix/$lib/$sysdata.py" > "$a$prefix/$lib/$sysdata.py"
cmp -s "$x$prefix/$lib/$sysdata.py" "$a$prefix/$lib/$sysdata.py" && fail "the arm64 stand-in's $sysdata.py did not change"

sh "$parity" "$x" "$a" > "$t/out" 2>&1 || fail "parity of a real stage and its arm64 stand-in: $(cat "$t/out")"
sh "$merge" --x86_64 "$x" --arm64 "$a" --out "$o" > "$t/out" 2>&1 || fail "merge of two slices differing only in Mach-O, pyconfig.h and $sysdata.py: $(tail -20 "$t/out")"

m="$o$prefix"
"$B/llvm-lipo" -info "$m/bin/python3.15" | grep -q 'are: x86_64 arm64' || fail "the merged python3.15 is $("$B/llvm-lipo" -info "$m/bin/python3.15")"
cmp -s "$m/$inc/pyconfig.h" "$MAVERICKS_ROOT/build/pyconfig-dispatch.h" || fail "the merged pyconfig.h is not build/pyconfig-dispatch.h"
cmp -s "$m/$inc/pyconfig-x86_64.h" "$x$prefix/$inc/pyconfig.h" || fail "pyconfig-x86_64.h is not the x86_64 slice's pyconfig.h"
cmp -s "$m/$inc/pyconfig-arm64.h" "$a$prefix/$inc/pyconfig.h" || fail "pyconfig-arm64.h is not the arm64 slice's pyconfig.h"
cmp -s "$m/$lib/$sysdata.py" "$MAVERICKS_ROOT/build/sysconfigdata-dispatch.py" || fail "the merged $sysdata.py is not build/sysconfigdata-dispatch.py"
cmp -s "$m/$lib/${sysdata}_x86_64.py" "$x$prefix/$lib/$sysdata.py" || fail "${sysdata}_x86_64.py is not the x86_64 slice's $sysdata.py"
cmp -s "$m/$lib/${sysdata}_arm64.py" "$a$prefix/$lib/$sysdata.py" || fail "${sysdata}_arm64.py is not the arm64 slice's $sysdata.py"

defines() { "$B/clang" --no-default-config --target="$1" -E -dM -x c - -I"$m/$inc" < "$t/tu.c" 2> "$t/cpp.err"; }
printf '#include "pyconfig.h"\n' > "$t/tu.c"
defines x86_64-apple-macos10.9 > "$t/x86.dM" || fail "pyconfig.h does not preprocess for x86_64: $(cat "$t/cpp.err")"
grep -q 'define PY315_TEST_ARM64_SLICE' "$t/x86.dM" && fail "pyconfig.h took the arm64 header for x86_64"
grep -q 'define SIZEOF_LONG 8' "$t/x86.dM" || fail "pyconfig.h took no pyconfig for x86_64"
defines arm64-apple-macos11.0 > "$t/arm.dM" || fail "pyconfig.h does not preprocess for arm64: $(cat "$t/cpp.err")"
grep -q 'define PY315_TEST_ARM64_SLICE 1' "$t/arm.dM" || fail "pyconfig.h did not take the arm64 header for arm64"
if defines i386-apple-macos10.9 > /dev/null; then fail "pyconfig.h preprocessed for i386, which this tree has no header for"; fi
grep -q 'x86_64 and arm64' "$t/cpp.err" || fail "pyconfig.h's refusal for i386 said: $(cat "$t/cpp.err")"
printf '#include <Python.h>\nint main(void) { return Py_IsInitialized(); }\n' > "$t/tu.c"
# shellcheck disable=SC2086
$CC -fsyntax-only -I"$m/$inc" -x c "$t/tu.c" 2> "$t/cc.err" || fail "Python.h does not compile for x86_64 with clang22: $(cat "$t/cc.err")"

run() { _c=$1; shift; env -i HOME="$t" PATH=/usr/bin:/bin "$m/bin/python3.15" -I -c "$_c" "$@" 2>&1; }
got="$(run 'import sysconfig; print(sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET"), sysconfig.get_platform())')" || fail "the merged python's sysconfig: $got"
[ "$got" = "10.9 macosx-10.9-x86_64" ] || fail "the merged python on x86_64 reads '$got' from sysconfig, not 10.9 macosx-10.9-x86_64"
got="$(run 'import platform; platform.machine = lambda: "arm64"
import sysconfig; print(sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET"))')" || fail "the merged python's sysconfig as arm64: $got"
[ "$got" = 11.0 ] || fail "the merged python on arm64 reads MACOSX_DEPLOYMENT_TARGET '$got' from sysconfig, not 11.0"
if got="$(run 'import platform; platform.machine = lambda: "ppc"
import sysconfig; sysconfig.get_config_vars()')"; then fail "sysconfig loaded build-time variables for ppc"; fi
case "$got" in *"x86_64 and arm64"*"'ppc'"*) ;; *) fail "sysconfig on ppc said: $got" ;; esac
cross() {
  env -i HOME="$t" PATH=/usr/bin:/bin "$@" -I -c 'import sys, sysconfig
v = sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET")
print(v, sys.modules[sysconfig._get_sysconfigdata_name()].__file__)' 2>&1
}
got="$(cross _PYTHON_HOST_PLATFORM=macosx-11.0-arm64 "$m/bin/python3.15")" || fail "the merged python cross-targeting arm64: $got"
[ "$got" = "11.0 $m/$lib/$sysdata.py" ] || fail "the merged python with _PYTHON_HOST_PLATFORM=macosx-11.0-arm64 read '$got', not 11.0 from its own shim"
got="$(cross _PYTHON_HOST_PLATFORM=macosx-10.13-universal2 "$m/bin/python3.15")" || fail "the merged python with a universal2 host platform: $got"
[ "$got" = "10.9 $m/$lib/$sysdata.py" ] ||
  fail "the merged python with _PYTHON_HOST_PLATFORM=macosx-10.13-universal2 read '$got', not 10.9 by platform.machine()"
for host in macosx-11.0-arm64:11.0 :10.9; do
  h="${host%%:*}"; want="${host#*:}"
  set -- _PYTHON_SYSCONFIGDATA_PATH="$m/$lib" "$x$prefix/bin/python3.15"
  [ -z "$h" ] || set -- _PYTHON_HOST_PLATFORM="$h" "$@"
  got="$(cross "$@")" || fail "the x86_64 slice's python reading the merged tree's sysconfig (host '$h'): $got"
  [ "$got" = "$want $m/$lib/$sysdata.py" ] ||
    fail "the x86_64 slice's python with _PYTHON_SYSCONFIGDATA_PATH at the merged tree (host '$h') read '$got', not $want from the merged shim"
done

for f in $arch_files; do
  [ ! -e "$m/$f" ] && [ ! -L "$m/$f" ] || fail "the merged real tree has a plain $f"
  cmp -s "$m/$f.x86_64" "$x$prefix/$f" && cmp -s "$m/$f.arm64" "$a$prefix/$f" || fail "the merged real tree's $f.<arch> are not the slices' $f"
done
printf '%s\n' $arch_files | sort > "$t/want"
sort "$m/$lib/mavergreen-arch-files.txt" | cmp -s "$t/want" - || fail "the real mavergreen-arch-files.txt lists: $(cat "$m/$lib/mavergreen-arch-files.txt")"
sh "$link" "$m" x86_64 > "$t/out" 2>&1 || fail "link-arch-files.sh x86_64 on the merged real tree: $(cat "$t/out")"
got="$(run 'import json, os, sysconfig
print(os.path.isfile(sysconfig.get_makefile_filename()), json.load(open(os.path.join(sysconfig.get_path("stdlib"), "build-details.json")))["platform"])')" ||
  fail "the linked real tree: $got"
[ "$got" = "True macosx-10.9-x86_64" ] || fail "the real tree linked for x86_64 reads '$got', not True macosx-10.9-x86_64"

( cd "$x" && find . -name '*.pyc' ) > "$t/pyc.want"
for s in x86_64 arm64; do
  for o_ in "" .opt-1 .opt-2; do
    echo "./${prefix#/}/$lib/__pycache__/${sysdata}_$s.cpython-$nodot$o_.pyc" >> "$t/pyc.want"
  done
done
sort -o "$t/pyc.want" "$t/pyc.want"
( cd "$o" && find . -name '*.pyc' | sort ) > "$t/pyc.got"
cmp -s "$t/pyc.want" "$t/pyc.got" || fail "the merged tree's .pyc files are not the slice's plus the per-arch $sysdata modules': $(diff "$t/pyc.want" "$t/pyc.got" | head -20)"
got="$(run 'import os, sys
bad = [os.path.join(d, f) for d, _, fs in os.walk(sys.argv[1]) for f in fs if f.endswith(".pyc") and open(os.path.join(d, f), "rb").read(8)[4:8] != b"\x03\0\0\0"]
print(len(bad), *bad[:3])' "$m/$lib")" || fail "could not read the merged .pyc files: $got"
[ "${got%% *}" = 0 ] || fail "the merged tree has .pyc files that are not checked-hash (they would go stale with the source mtimes the merge does not keep): $got"
echo "PASS real stages: the merged tree is universal, pyconfig.h picks x86_64's header for x86_64 and arm64's for arm64, sysconfig dispatches by platform.machine() or _PYTHON_HOST_PLATFORM from its own directory, the per-arch files link for x86_64, and the library is recompiled checked-hash"
echo "PASS: merge (ran: tiny stages, real stages)"
