#!/bin/sh
# platform: host-agnostic
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build/fetch-ingredient.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/fetch-ingredient-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT

mkdir -p "$t/srv" "$t/pins/zstd" "$t/pins/xz" "$t/pins/sqlite" "$t/pins/make"
tarball() {
  mkdir -p "$t/tree/$1"; echo hello > "$t/tree/$1/README"
  tar -czf "$t/srv/$1.tar.gz" -C "$t/tree" "$1"
  shasum -a 256 "$t/srv/$1.tar.gz" | cut -d' ' -f1
}
zsha="$(tarball zstd-9.9.9)"
xsha="$(tarball xz-9.9.9)"
ssha="$(tarball sqlite-autoconf-3540000)"
msha="$(tarball make-9.9.9)"
bad=0000000000000000000000000000000000000000000000000000000000000000
echo 9.9.9 > "$t/pins/zstd/version"

run() {
  MAVERICKS_BUILD_ROOT="$t/root" PY_COMPONENTS="$t/pins" PY_INGREDIENT_BASE_URL="file://$t/srv" \
    sh "$script" "$1" --dest "$t/out" 2>"$t/err"
}
expect_fail() {
  if run "$1" >/dev/null; then echo "FAIL $2: accepted"; exit 1; fi
  grep -q "$3" "$t/err" || { echo "FAIL $2: stderr lacks '$3': $(cat "$t/err")"; exit 1; }
}

printf '%s  zstd-9.9.9.tar.gz\n' "$zsha" > "$t/srv/zstd-9.9.9.tar.gz.sha256"
dir="$(run zstd)" || { echo "FAIL zstd good: $(cat "$t/err")"; exit 1; }
[ -f "$dir/README" ] || { echo "FAIL zstd good: no tree at $dir"; exit 1; }

printf '%s  zstd-9.9.8.tar.gz\n' "$zsha" > "$t/srv/zstd-9.9.9.tar.gz.sha256"
expect_fail zstd "zstd unlisted" "not listed"

printf '%s  zstd-9.9.9.tar.gz\n' "$bad" > "$t/srv/zstd-9.9.9.tar.gz.sha256"
expect_fail zstd "zstd sha mismatch" "$bad"

printf 'TAG=v9.9.9\nSHA256=%s\n' "$xsha" > "$t/pins/xz/version"
dir="$(run xz)" || { echo "FAIL xz good: $(cat "$t/err")"; exit 1; }
[ -f "$dir/README" ] || { echo "FAIL xz good: no tree at $dir"; exit 1; }
printf 'TAG=v9.9.9\nSHA256=%s\n' "$bad" > "$t/pins/xz/version"
expect_fail xz "xz sha mismatch" "$bad"
printf 'TAG=v9.9.9\n' > "$t/pins/xz/version"
expect_fail xz "xz no sha" "names no SHA256"

printf 'VERSION=3.54.0\nYEAR=2026\nSHA256=%s\n' "$ssha" > "$t/pins/sqlite/version"
dir="$(run sqlite)" || { echo "FAIL sqlite good: $(cat "$t/err")"; exit 1; }
[ -f "$dir/README" ] || { echo "FAIL sqlite good: no tree at $dir"; exit 1; }
printf 'VERSION=3.54.0\nSHA256=%s\n' "$ssha" > "$t/pins/sqlite/version"
expect_fail sqlite "sqlite no year" "names no YEAR"

printf 'VERSION=9.9.9\nSHA256=%s\n' "$msha" > "$t/pins/make/version"
dir="$(run make)" || { echo "FAIL make good: $(cat "$t/err")"; exit 1; }
[ -f "$dir/README" ] || { echo "FAIL make good: no tree at $dir"; exit 1; }
printf 'VERSION=9.9.9\nSHA256=%s\n' "$bad" > "$t/pins/make/version"
expect_fail make "make sha mismatch" "$bad"
printf 'SHA256=%s\n' "$msha" > "$t/pins/make/version"
expect_fail make "make no version" "names no VERSION"

echo "PASS: fetch-ingredient"
