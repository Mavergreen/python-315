#!/bin/sh
# platform: host-agnostic
#   usage: build/link-arch-files.sh PREFIX x86_64|arm64
#          For a tree build/merge.sh made, links each plain name that lib/python3.*/mavergreen-arch-files.txt
#          lists (a path relative to PREFIX) to its ARCH copy beside it, <name>.ARCH, by a relative symlink,
#          replacing a link already there. Checks every entry before changing any: refuses, changing
#          nothing, when a plain name is anything but a symlink or nothing, or when an ARCH copy is
#          missing. Running it again changes nothing. A pkg's postinstall calls it with the installing
#          Mac's hardware arch.
set -eu
usage() { echo "usage: build/link-arch-files.sh PREFIX x86_64|arm64" >&2; exit 2; }
die() { echo "link-arch-files: $*" >&2; exit 1; }
[ "$#" -eq 2 ] || usage
prefix=$1; arch=$2
case "$arch" in x86_64|arm64) ;; *) usage ;; esac
set -- "$prefix"/lib/python3.*/mavergreen-arch-files.txt
[ "$#" -eq 1 ] && [ -f "$1" ] || die "expected one lib/python3.*/mavergreen-arch-files.txt under $prefix, found: $*"
list=$1

n=0
while IFS= read -r rel || [ -n "$rel" ]; do
  case "$rel" in ''|/*|..|../*|*/..|*/../*) die "$list lists '$rel', which is not a path inside $prefix" ;; esac
  [ -f "$prefix/$rel.$arch" ] && [ ! -L "$prefix/$rel.$arch" ] || die "no $prefix/$rel.$arch to link $rel to"
  if [ -L "$prefix/$rel" ] || [ ! -e "$prefix/$rel" ]; then :; else
    die "$prefix/$rel is not a symlink; refusing to replace it"
  fi
  n=$((n + 1))
done < "$list"
[ "$n" -gt 0 ] || die "$list lists nothing"

while IFS= read -r rel || [ -n "$rel" ]; do
  rm -f "$prefix/$rel"
  ln -s "${rel##*/}.$arch" "$prefix/$rel"
done < "$list"
