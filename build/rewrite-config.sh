#!/bin/sh
# platform: host-agnostic
#   usage: build/rewrite-config.sh --arch x86_64|arm64 --tree TREE --srcdir DIR [--srcdir-relative PATH]
#              --builddir DIR --deps DIR --build-root DIR --sdk DIR --clang22 DIR
#              [--recaulk-include DIR --recaulk-libs WORDS] [--build-python PATH]
#          Rewrites every text file in TREE (an installed python315) that names a build-host path, prints
#          each rewritten file's path relative to TREE, and removes the stale .pyc files of a rewritten .py.
#          In the installed sysconfig, config Makefile, pkgconfig and the rest:
#          - clang22 is /usr/local/mavergreen/clang22, with the same target flags;
#          - x86_64's SDK is /usr/local/mavergreen/sdk109/SDKs/MacOSX10.9.sdk, where Longboat puts it;
#          - arm64 has no family SDK path, so its -isysroot and SDK -I/-L flags go: an arm64 extension build
#            needs SDKROOT set, since CC carries --no-default-config and clang22 never runs xcrun;
#          - the static deps' -I/-L, Recaulk's -isystem and link words and any -ffile-prefix-map go;
#          - the source directory (absolute, or as configure was given it relative to the build
#            directory) and the build directory become LIBPL, sysconfig's srcdir for an installed Python;
#          - a hermetic HOME under the build root becomes ~;
#          - a cross build's --build-python, an absolute PATH, names a tree two levels above it, and that
#            tree becomes /usr/local/mavergreen/python315 (in CONFIG_ARGS and PYTHON_FOR_BUILD).
#          Fails, naming each file, when any file in TREE, text or binary, still names one of those paths,
#          the build root, $HOME, Library/Caches or /var/folders.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
usage() {
  echo "usage: build/rewrite-config.sh --arch x86_64|arm64 --tree TREE --srcdir DIR [--srcdir-relative PATH]" \
    "--builddir DIR --deps DIR --build-root DIR --sdk DIR --clang22 DIR [--recaulk-include DIR --recaulk-libs WORDS]" \
    "[--build-python PATH]" >&2
  exit 2
}
die() { echo "rewrite-config: $*" >&2; exit 1; }
arch=""; tree=""; srcdir=""; srcrel=""; builddir=""; deps=""; br=""; sdk=""; clang22=""; rinc=""; rlibs=""; bpy=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --arch) arch=$2 ;;
    --tree) tree=$2 ;;
    --srcdir) srcdir=$2 ;;
    --srcdir-relative) srcrel=$2 ;;
    --builddir) builddir=$2 ;;
    --deps) deps=$2 ;;
    --build-root) br=$2 ;;
    --sdk) sdk=$2 ;;
    --clang22) clang22=$2 ;;
    --recaulk-include) rinc=$2 ;;
    --recaulk-libs) rlibs=$2 ;;
    --build-python) bpy=$2 ;;
    *) usage ;;
  esac
  shift 2
done
case "$arch" in x86_64|arm64) ;; *) usage ;; esac
for v in "$tree" "$srcdir" "$builddir" "$deps" "$br" "$sdk" "$clang22"; do [ -n "$v" ] || usage; done
[ -d "$tree" ] || die "no $tree"
if [ "$arch" = x86_64 ]; then
  [ -n "$rinc" ] && [ -n "$rlibs" ] || die "x86_64 links Recaulk: give --recaulk-include and --recaulk-libs"
else
  [ -z "$rinc$rlibs" ] || die "arm64 links no Recaulk"
fi
bpyroot=""
if [ -n "$bpy" ]; then
  case "$bpy" in /*) ;; *) die "--build-python $bpy is not an absolute path" ;; esac
  bpyroot="${bpy%/*}"; bpyroot="${bpyroot%/*}"
  [ -n "$bpyroot" ] || die "--build-python $bpy has no tree two levels above it"
fi
ver="$(tr -d '[:space:]' < "$here/../UPSTREAM_VERSION" | cut -d. -f1,2)"
prefix=/usr/local/mavergreen/python315
libpl="$prefix/lib/python$ver/config-$ver-darwin"
sdk109=/usr/local/mavergreen/sdk109/SDKs/MacOSX10.9.sdk
clang22_installed=/usr/local/mavergreen/clang22

t="$(mktemp -d "${TMPDIR:-/tmp}/rewrite-config.XXXXXX")"
trap 'rm -rf "$t"' EXIT
tab="$(printf '\t')"
rule() {
  case "$2$3" in *"$tab"*) die "a path holds a tab: $2" ;; esac
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$t/rules"
}
spellings() {
  if [ -d "$1" ]; then _sp="$(cd -P "$1" && pwd)"; [ "$_sp" = "$1" ] || printf '%s\n' "$_sp"; fi
  printf '%s\n' "$1"
}
: > "$t/rules"
[ -z "$bpyroot" ] || for d in $(spellings "$bpyroot"); do [ "$d" = "$prefix" ] || rule map "$d" "$prefix"; done
if [ "$arch" = x86_64 ]; then
  rule drop "$rlibs" ""
  for d in $(spellings "$rinc"); do rule drop "-isystem $d" ""; done
fi
for d in $(spellings "$deps"); do rule drop "-I$d" ""; rule drop "-L$d" ""; done
for d in $(spellings "$br"); do rule drop "-ffile-prefix-map=$d" ""; done
for d in $(spellings "$sdk"); do
  case "$arch" in
    x86_64) rule map "$d" "$sdk109" ;;
    arm64) rule drop "-isysroot $d" ""; rule drop "-I$d" ""; rule drop "-L$d" "" ;;
  esac
done
[ "$clang22" = "$clang22_installed" ] || for d in $(spellings "$clang22"); do rule map "$d" "$clang22_installed"; done
[ -z "$srcrel" ] || for d in $(spellings "$builddir"); do rule map "$d/$srcrel" "$libpl"; done
for d in $(spellings "$srcdir") $(spellings "$builddir"); do rule map "$d" "$libpl"; done
[ -z "$srcrel" ] || rule map "$srcrel" "$libpl"
for d in $(spellings "$br"); do rule run "$d/home." "~"; done

{
  for d in $(spellings "$br") $(spellings "$srcdir") $(spellings "$builddir") $(spellings "$deps") \
      $(spellings "$sdk") $(spellings "$clang22") ${rinc:+$(spellings "$rinc")} ${bpyroot:+$(spellings "$bpyroot")}; do
    [ "$d" = "$clang22_installed" ] || [ "$d" = "$prefix" ] || printf '%s\n' "$d"
  done
  case "${HOME:-/}" in /) ;; *) printf '%s\n' "$HOME" ;; esac
  printf '%s\n' Library/Caches /var/folders
} > "$t/patterns"

files_naming() {
  find "$tree" -type f -exec grep "$@" -l -F -f "$t/patterns" {} + 2> "$t/grep.err" || true
  [ ! -s "$t/grep.err" ] || die "could not search $tree: $(cat "$t/grep.err")"
}
files_naming -I > "$t/files"
while IFS= read -r f; do
  awk -v rules="$t/rules" '
    function apply(kind, s, p, r,    out, i, j, pre, post) {
      out = ""
      while ((i = index(s, p)) > 0) {
        pre = substr(s, 1, i - 1); j = i + length(p)
        if (kind == "drop") {
          while (j <= length(s) && index(" \t\047\"\\,", substr(s, j, 1)) == 0) j++
          post = substr(s, j)
          if (substr(pre, length(pre), 1) == " ") pre = substr(pre, 1, length(pre) - 1)
          else if (substr(post, 1, 1) == " ") post = substr(post, 2)
          out = out pre; s = post
        } else {
          if (kind == "run") while (j <= length(s) && substr(s, j, 1) ~ /[A-Za-z0-9]/) j++
          out = out pre r; s = substr(s, j)
        }
      }
      return out s
    }
    BEGIN { while ((getline line < rules) > 0) { n++; split(line, f, "\t"); kind[n] = f[1]; from[n] = f[2]; to[n] = f[3] } }
    { s = $0; for (k = 1; k <= n; k++) s = apply(kind[k], s, from[k], to[k]); print s }
  ' "$f" > "$t/new" || die "could not rewrite $f"
  cat "$t/new" > "$f"
  case "$f" in
    *.py) _b="${f##*/}"; for _c in "${f%/*}/__pycache__/${_b%.py}".*.pyc; do rm -f "$_c"; done ;;
  esac
  printf '%s\n' "${f#"$tree"/}"
done < "$t/files"

files_naming > "$t/left"
if [ -s "$t/left" ]; then
  while IFS= read -r f; do
    printf 'rewrite-config: %s still names' "$f" >&2
    while IFS= read -r p; do grep -q -F -e "$p" "$f" && printf ' %s' "$p" >&2; done < "$t/patterns"
    echo >&2
  done < "$t/left"
  die "files in $tree still name build-host paths (above)"
fi
