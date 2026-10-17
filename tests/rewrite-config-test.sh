#!/bin/sh
# platform: host-agnostic
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build/rewrite-config.sh"
ver="$(tr -d '[:space:]' < "$here/../UPSTREAM_VERSION")"
mm="$(printf '%s' "$ver" | cut -d. -f1,2)"
prefix=/usr/local/mavergreen/python315
libpl="$prefix/lib/python$mm/config-$mm-darwin"
t="$(mktemp -d "${TMPDIR:-/tmp}/rewrite-config-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }

br="$t/br/python-315"
work="$br/cpython-x86_64.Ab12Cd"
src="$work/src/Python-$ver"; bld="$work/build"; deps="$work/deps"
recaulk="$br/toolchain/recaulk-1"
clang="$br/toolchain/clang22-cross-1"
home="$t/home"
sdk="$home/Library/Caches/mavericks-sdk/MacOSX10.9.sdk"
mkdir -p "$src" "$bld" "$deps" "$recaulk" "$clang" "$sdk" "$br/home.Xy34Zw"
bldp="$(cd -P "$bld" && pwd)"
libs="$recaulk/lib/librecaulk.a -framework Security -lobjc"

stage() {
  _arch=$1; _tree="$t/$_arch"; _l="$_tree/lib/python$mm"
  case "$_arch" in
    x86_64) _tgt=x86_64-apple-macos10.9; _cpp="-I$deps/include -isystem $recaulk/include/recaulk"; _libs="$libs " ;;
    arm64) _tgt=arm64-apple-macos11.0; _cpp="-I$deps/include"; _libs="" ;;
  esac
  mkdir -p "$_l/config-$mm-darwin" "$_tree/lib/pkgconfig" "$_tree/bin"
  cat > "$_l/_sysconfigdata__darwin_darwin.py" <<EOF
build_time_vars = {
 'CC': '$clang/bin/clang --no-default-config --target=$_tgt -isysroot $sdk -fuse-ld=lld',
 'CONFIGURE_CPPFLAGS': '$_cpp',
 'CONFIGURE_LDFLAGS': '-L$deps/lib -Wl,-headerpad_max_install_names',
 'CONFIG_ARGS': "'--prefix=$prefix' 'CPPFLAGS=$_cpp' 'LIBS=${_libs% }'",
 'LIBS': '-ldl ${_libs}-framework CoreFoundation',
 'MODULE__CTYPES_CFLAGS': '-fno-strict-overflow -I$sdk/usr/include/ffi -DUSING_APPLE_OS_LIBFFI=1',
 'PY_CPPFLAGS': '-IInclude -I$src/Include -I$deps/include',
 'CPPFLAGS': '-IInclude -I../src/Python-$ver/Include',
 'VPATH': '../src/Python-$ver',
 'abs_srcdir': '$bld/../src/Python-$ver',
 'abs_builddir': '$bldp',
 'prefix': '$prefix',
 'srcdir': '$src',
}
EOF
  printf '{\n  "srcdir": "%s",\n  "userbase": "%s/home.Xy34Zw/.local"\n}' "$libpl" "$br" > "$_l/_sysconfig_vars__darwin_darwin.json"
  printf 'prefix=%s\nsrcdir=\t\t%s\nabs_builddir=\t%s\nLIBS=\t\t-ldl %s-framework CoreFoundation\n' "$prefix" "$src" "$bldp" "$_libs" > "$_l/config-$mm-darwin/Makefile"
  printf '/* Generated automatically from %s/Modules/config.c.in by makesetup. */\n' "$src" > "$_l/config-$mm-darwin/config.c"
  printf 'prefix=%s\nLibs.private: -ldl %s-framework CoreFoundation\n' "$prefix" "$_libs" > "$_tree/lib/pkgconfig/python-$mm.pc"
  printf '#!%s/bin/python%s\nCC = "%s/bin/clang"\n' "$prefix" "$mm" "$clang" > "$_tree/bin/python$mm-config"
  chmod 755 "$_tree/bin/python$mm-config"
  printf 'import os\n' > "$_l/untouched.py"
  printf 'bin\000%s\n' "$prefix" > "$_l/binary.so"
  mkdir -p "$_l/__pycache__"
  printf 'pyc\000%s\n' "$src" > "$_l/__pycache__/_sysconfigdata__darwin_darwin.cpython-315.pyc"
  printf 'pyc\000%s\n' "$src" > "$_l/__pycache__/_sysconfigdata__darwin_darwin.cpython-315.opt-1.pyc"
  printf 'pyc\000\n' > "$_l/__pycache__/untouched.cpython-315.pyc"
}
rewrite() {
  _arch=$1; shift
  set -- --arch "$_arch" --tree "$t/$_arch" --srcdir "$src" --srcdir-relative "../src/Python-$ver" --builddir "$bld" --deps "$deps" --build-root "$br" \
    --sdk "$sdk" --clang22 "$clang" "$@"
  [ "$_arch" = arm64 ] || set -- "$@" --recaulk-include "$recaulk/include/recaulk" --recaulk-libs "$libs"
  HOME="$home" sh "$script" "$@" > "$t/out" 2>&1
}
var() { grep "^ *'$1'" "$2" | sed "s/^ *'$1': //; s/,\$//"; }
is() { [ "$(var "$1" "$t/$2/lib/python$mm/_sysconfigdata__darwin_darwin.py")" = "$3" ] || fail "$2 $1 is $(var "$1" "$t/$2/lib/python$mm/_sysconfigdata__darwin_darwin.py"), not $3"; }

stage x86_64
cp "$t/x86_64/lib/python$mm/untouched.py" "$t/untouched.before"
cp "$t/x86_64/lib/python$mm/binary.so" "$t/binary.before"
rewrite x86_64 || fail "the x86_64 rewrite failed: $(cat "$t/out")"
sort "$t/out" > "$t/listed"
printf '%s\n' bin/python$mm-config lib/pkgconfig/python-$mm.pc "lib/python$mm/_sysconfig_vars__darwin_darwin.json" \
  "lib/python$mm/_sysconfigdata__darwin_darwin.py" "lib/python$mm/config-$mm-darwin/Makefile" \
  "lib/python$mm/config-$mm-darwin/config.c" | sort > "$t/want"
cmp -s "$t/want" "$t/listed" || fail "rewrite-config.sh listed: $(cat "$t/out")"
x="lib/python$mm"
is CC x86_64 "'/usr/local/mavergreen/clang22/bin/clang --no-default-config --target=x86_64-apple-macos10.9 -isysroot /usr/local/mavergreen/sdk109/SDKs/MacOSX10.9.sdk -fuse-ld=lld'"
is CONFIGURE_CPPFLAGS x86_64 "''"
is CONFIGURE_LDFLAGS x86_64 "'-Wl,-headerpad_max_install_names'"
is CONFIG_ARGS x86_64 "\"'--prefix=$prefix' 'CPPFLAGS=' 'LIBS='\""
is LIBS x86_64 "'-ldl -framework CoreFoundation'"
is MODULE__CTYPES_CFLAGS x86_64 "'-fno-strict-overflow -I/usr/local/mavergreen/sdk109/SDKs/MacOSX10.9.sdk/usr/include/ffi -DUSING_APPLE_OS_LIBFFI=1'"
is PY_CPPFLAGS x86_64 "'-IInclude -I$libpl/Include'"
is abs_builddir x86_64 "'$libpl'"
is srcdir x86_64 "'$libpl'"
is VPATH x86_64 "'$libpl'"
is abs_srcdir x86_64 "'$libpl'"
is CPPFLAGS x86_64 "'-IInclude -I$libpl/Include'"
grep -q '"userbase": "~/.local"' "$t/x86_64/$x/_sysconfig_vars__darwin_darwin.json" || fail "the hermetic HOME in userbase did not become ~: $(cat "$t/x86_64/$x/_sysconfig_vars__darwin_darwin.json")"
printf 'prefix=%s\nsrcdir=\t\t%s\nabs_builddir=\t%s\nLIBS=\t\t-ldl -framework CoreFoundation\n' "$prefix" "$libpl" "$libpl" > "$t/want"
cmp -s "$t/want" "$t/x86_64/$x/config-$mm-darwin/Makefile" || fail "the config Makefile became: $(cat "$t/x86_64/$x/config-$mm-darwin/Makefile")"
grep -q -F "from $libpl/Modules/config.c.in by" "$t/x86_64/$x/config-$mm-darwin/config.c" || fail "config.c became: $(cat "$t/x86_64/$x/config-$mm-darwin/config.c")"
grep -q -F 'CC = "/usr/local/mavergreen/clang22/bin/clang"' "$t/x86_64/bin/python$mm-config" || fail "python$mm-config's clang22 path was not rewritten"
[ -x "$t/x86_64/bin/python$mm-config" ] || fail "rewriting python$mm-config lost its execute bit"
cmp -s "$t/untouched.before" "$t/x86_64/$x/untouched.py" || fail "a file naming no build-host path changed"
cmp -s "$t/binary.before" "$t/x86_64/$x/binary.so" || fail "a binary file was rewritten"
if ls "$t/x86_64/$x/__pycache__"/_sysconfigdata__darwin_darwin.* > /dev/null 2>&1; then
  fail "the rewritten _sysconfigdata kept its stale .pyc files"; fi
[ -f "$t/x86_64/$x/__pycache__/untouched.cpython-315.pyc" ] || fail "a .pyc of a file not rewritten went"

stage arm64
rewrite arm64 || fail "the arm64 rewrite failed: $(cat "$t/out")"
is CC arm64 "'/usr/local/mavergreen/clang22/bin/clang --no-default-config --target=arm64-apple-macos11.0 -fuse-ld=lld'"
is MODULE__CTYPES_CFLAGS arm64 "'-fno-strict-overflow -DUSING_APPLE_OS_LIBFFI=1'"
is CONFIGURE_CPPFLAGS arm64 "''"
grep -q -F 'lib/pkgconfig' "$t/out" && fail "the arm64 pkgconfig names no build-host path, yet was rewritten"
cmp -s "$t/x86_64/lib/pkgconfig/python-$mm.pc" "$t/arm64/lib/pkgconfig/python-$mm.pc" || fail "the x86_64 pkgconfig still differs from arm64's: $(cat "$t/x86_64/lib/pkgconfig/python-$mm.pc")"

mkdir -p "$t/stage-arm64$prefix/bin"
ln -s "$t/stage-arm64" "$home/stage-arm64"
bpy="$home/stage-arm64$prefix/bin/python$mm"
bpyp="$(cd -P "${bpy%/*}" && pwd)/python$mm"
cross_stage() {
  rm -rf "$t/x86_64"; stage x86_64
  _sd="$t/x86_64/$x/_sysconfigdata__darwin_darwin.py"
  sed "s|^ 'CONFIG_ARGS': \"|&'--with-build-python=$bpy' |" "$_sd" > "$t/sd" && cat "$t/sd" > "$_sd"
  printf "PYTHON_FOR_BUILD=\t_PYTHON_PROJECT_BASE=. %s -E\nPYTHON_FOR_REGEN?=%s\n" "$bpy" "$bpyp" \
    >> "$t/x86_64/$x/config-$mm-darwin/Makefile"
}
cross_stage
if rewrite x86_64; then fail "a cross build's configuration naming its build python passed without --build-python"; fi
cross_stage
rewrite x86_64 --build-python "$bpy" || fail "the cross rewrite failed: $(cat "$t/out")"
is CONFIG_ARGS x86_64 "\"'--with-build-python=$prefix/bin/python$mm' '--prefix=$prefix' 'CPPFLAGS=' 'LIBS='\""
grep -q -x -F "PYTHON_FOR_BUILD=	_PYTHON_PROJECT_BASE=. $prefix/bin/python$mm -E" "$t/x86_64/$x/config-$mm-darwin/Makefile" \
  || fail "PYTHON_FOR_BUILD became: $(grep PYTHON_FOR_BUILD "$t/x86_64/$x/config-$mm-darwin/Makefile")"
grep -q -x -F "PYTHON_FOR_REGEN?=$prefix/bin/python$mm" "$t/x86_64/$x/config-$mm-darwin/Makefile" \
  || fail "the build python's physical spelling became: $(grep PYTHON_FOR_REGEN "$t/x86_64/$x/config-$mm-darwin/Makefile")"
cross_stage
printf 'stab\000%s\n' "$bpyp" > "$t/x86_64/$x/leftover.so"
if rewrite x86_64 --build-python "$bpy"; then fail "rewrite-config.sh passed a binary file naming the build python"; fi
grep -q -F "$x/leftover.so" "$t/out" || fail "the refusal for the build python did not name the file: $(cat "$t/out")"
cross_stage
if rewrite x86_64 --build-python "stage-arm64$prefix/bin/python$mm"; then fail "rewrite-config.sh took a relative --build-python"; fi
grep -q 'is not an absolute path' "$t/out" || fail "the refusal of a relative --build-python does not say why: $(cat "$t/out")"

for left in "$br/tools/make-4.4.1/bin/make" "$home/.netrc" "/Users/somebody/Library/Caches/x" "/private/var/folders/zz/T/x" \
    "/var/folders/zz/T/x" "binary:$bldp/Modules/_bisect.o"; do
  rm -rf "$t/x86_64"; stage x86_64
  case "$left" in
    binary:*) printf 'stab\000%s\n' "${left#binary:}" > "$t/x86_64/$x/leftover.txt" ;;
    *) printf 'MAKE=%s\n' "$left" > "$t/x86_64/$x/leftover.txt" ;;
  esac
  if rewrite x86_64; then fail "rewrite-config.sh passed a text file naming $left"; fi
  grep -q -F "$x/leftover.txt" "$t/out" || fail "the refusal for $left did not name the file: $(cat "$t/out")"
done

if HOME="$home" sh "$script" --arch ppc --tree "$t/x86_64" > "$t/out" 2>&1; then fail "rewrite-config.sh took --arch ppc"; fi
echo "PASS: rewrite-config maps clang22, the x86_64 SDK, sources, HOME and a cross build's build python to installed paths, drops arm64's SDK and the deps' and Recaulk's flags, and refuses any build-host path left"
