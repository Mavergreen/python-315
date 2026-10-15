#!/bin/sh
# platform: host-agnostic
#   usage: build/fetch-ingredient.sh sqlite|xz|zstd [--dest DIR]
#          Prints the path of a freshly extracted DIR/<tree> of the release components/<name>/version
#          pins, verified first with shasum: zstd against upstream's zstd-<version>.tar.gz.sha256,
#          fetched afresh every run; sqlite and xz against the SHA256 in their pin file.
#          Tarballs are cached in $MAVERICKS_BUILD_ROOT/python-315/ingredients-cache and verified on
#          every use. Exit 1 on any fetch or verification failure, 2 on a usage error.
#          Fixture mode: PY_INGREDIENT_BASE_URL replaces the directory each file is downloaded from
#          (a file:// URL works) and PY_COMPONENTS the components/ directory the pins are read from.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"

usage() { echo "usage: fetch-ingredient.sh sqlite|xz|zstd [--dest DIR]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
name=$1; shift
tmp="${TMPDIR:-/tmp}"
root="${MAVERICKS_BUILD_ROOT:-${tmp%/}/mm-build}/python-315"
dest="$root/ingredients"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) [ "$#" -ge 2 ] || usage; dest=$2; shift 2 ;;
    *) usage ;;
  esac
done
pinfile="${PY_COMPONENTS:-$here/../components}/$name/version"
case "$name" in sqlite|xz|zstd) ;; *) usage ;; esac
[ -f "$pinfile" ] || { echo "fetch-ingredient: no pin file $pinfile" >&2; exit 2; }

key() { sed -n "s/^$1=//p" "$pinfile" | tr -d '[:space:]'; }
need() { [ -n "$2" ] || { echo "fetch-ingredient: $pinfile names no $1" >&2; exit 1; }; }

case "$name" in
  sqlite)
    v="$(key VERSION)"; year="$(key YEAR)"; sha="$(key SHA256)"
    need VERSION "$v"; need YEAR "$year"; need SHA256 "$sha"
    enc="$(printf '%s\n' "$v" | awk -F. 'NF == 3 { printf "%d%02d%02d00\n", $1, $2, $3 }')"
    need "VERSION of the form X.Y.Z" "$enc"
    tarball="sqlite-autoconf-$enc.tar.gz"; tree="sqlite-autoconf-$enc"
    base="https://www.sqlite.org/$year" ;;
  xz)
    tag="$(key TAG)"; sha="$(key SHA256)"
    need TAG "$tag"; need SHA256 "$sha"
    v="${tag#v}"; tarball="xz-$v.tar.gz"; tree="xz-$v"
    base="https://github.com/tukaani-project/xz/releases/download/$tag" ;;
  zstd)
    v="$(tr -d '[:space:]' < "$pinfile")"
    need "version" "$v"
    tarball="zstd-$v.tar.gz"; tree="zstd-$v"
    base="https://github.com/facebook/zstd/releases/download/v$v" ;;
esac
base="${PY_INGREDIENT_BASE_URL:-$base}"

if [ "$name" = zstd ]; then
  sums="$(mktemp "${TMPDIR:-/tmp}/fetch-ingredient.XXXXXX")"
  trap 'rm -f "$sums"' EXIT
  shipyard_curl --quiet "$base/$tarball.sha256" "$sums" || {
    echo "fetch-ingredient: could not fetch $base/$tarball.sha256" >&2; exit 1; }
  sha="$(awk -v f="$tarball" '$2 == f || $2 == "*" f { print $1 }' "$sums")"
  case "$sha" in
    *[!0-9a-f]*|'') echo "fetch-ingredient: $tarball is not listed (once) in $base/$tarball.sha256" >&2; exit 1 ;;
  esac
fi
case "$sha" in
  *[!0-9a-f]*|'') echo "fetch-ingredient: '$sha' is not a SHA-256 for $tarball" >&2; exit 1 ;;
esac
[ "${#sha}" -eq 64 ] || { echo "fetch-ingredient: '$sha' is not a SHA-256 for $tarball" >&2; exit 1; }

shipyard_fetch_verified "$base/$tarball" "$sha" "$root/ingredients-cache" "$tarball" || {
  echo "fetch-ingredient: $tarball could not be fetched and verified against $sha" >&2; exit 1; }
mkdir -p "$dest"
rm -rf "${dest:?}/$tree"
tar -xzf "$root/ingredients-cache/$tarball" -C "$dest"
[ -d "$dest/$tree" ] || { echo "fetch-ingredient: $tarball did not extract to $dest/$tree" >&2; exit 1; }
printf '%s\n' "$dest/$tree"
