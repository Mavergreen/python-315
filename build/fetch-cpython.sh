#!/bin/sh
# platform: host-agnostic
#   usage: build/fetch-cpython.sh [--version V] [--dest DIR]
#          Prints the path of a freshly extracted CPython source tree whose tarball matched
#          python.org's published SHA-256 and size; exits 1 on any verification failure.
#          Fixture mode (no network): CPYTHON_API_JSON=<release_file JSON> CPYTHON_TARBALL=<tarball>.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"

version="$(tr -d '[:space:]' < "$here/../UPSTREAM_VERSION")"
dest=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) version="${2:?--version needs a value}"; shift 2 ;;
    --dest) dest="${2:?--dest needs a value}"; shift 2 ;;
    *) echo "usage: fetch-cpython.sh [--version V] [--dest DIR]" >&2; exit 2 ;;
  esac
done
[ -n "$dest" ] || dest="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/python-315/src"

PY=/usr/bin/python2.7
[ -x "$PY" ] || PY="$(command -v python2.7 || command -v python3)"
tarname="Python-${version}.tar.xz"
work="$(mktemp -d "${TMPDIR:-/tmp}/fetch-cpython.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [ -n "${CPYTHON_API_JSON:-}" ]; then
  cp "$CPYTHON_API_JSON" "$work/files.json"
else
  api=https://www.python.org/api/v2/downloads
  shipyard_curl --quiet "$api/release/?name=Python%20${version}" "$work/release.json"
  id="$("$PY" -c 'import json, sys
r = json.load(open(sys.argv[1]))
r = r[0] if r else {}
i = r.get("id") or str(r.get("resource_uri", "")).rstrip("/").split("/")[-1]
sys.stdout.write(str(i))' "$work/release.json")"
  [ -n "$id" ] || { echo "fetch-cpython: python.org lists no release Python ${version}" >&2; exit 1; }
  shipyard_curl --quiet "$api/release_file/?release=${id}" "$work/files.json"
fi

expect="$("$PY" -c 'import json, sys
for f in json.load(open(sys.argv[1])):
    if str(f.get("url", "")).endswith("/" + sys.argv[2]):
        sys.stdout.write("%s %s" % (f.get("sha256_sum", ""), f.get("filesize", "")))
        break' "$work/files.json" "$tarname")"
want_sha="${expect%% *}"
want_size="${expect#* }"
if [ -z "$expect" ] || [ -z "$want_sha" ] || [ -z "$want_size" ] || [ "$want_size" = "$expect" ]; then
  echo "fetch-cpython: $tarname not listed (with sha256 and size) by python.org" >&2
  exit 1
fi

mkdir -p "$dest"
tarball="$dest/$tarname"

verify() {
  [ -f "$1" ] || return 1
  got_size="$(wc -c < "$1" | tr -d ' ')"
  got_sha="$(shasum -a 256 "$1" | cut -d' ' -f1)"
  [ "$got_size" = "$want_size" ] && [ "$got_sha" = "$want_sha" ]
}

if [ -n "${CPYTHON_TARBALL:-}" ]; then
  cp "$CPYTHON_TARBALL" "$tarball"
elif ! verify "$tarball"; then
  rm -f "$tarball"
  shipyard_curl --quiet "https://www.python.org/ftp/python/${version}/${tarname}" "$tarball"
fi

if ! verify "$tarball"; then
  echo "fetch-cpython: $tarname does not match python.org: expected sha256 $want_sha size $want_size, got sha256 $got_sha size $got_size" >&2
  exit 1
fi

tree="$dest/Python-${version}"
rm -rf "$tree"
tar -xJf "$tarball" -C "$dest"
[ -d "$tree" ] || { echo "fetch-cpython: $tarname did not extract to $tree" >&2; exit 1; }
printf '%s\n' "$tree"
