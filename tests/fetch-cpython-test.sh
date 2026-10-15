#!/bin/sh
# platform: host-agnostic
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build/fetch-cpython.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/fetch-cpython-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT

mkdir -p "$t/src/Python-9.9.9"
echo hello > "$t/src/Python-9.9.9/README"
tar -cJf "$t/Python-9.9.9.tar.xz" -C "$t/src" Python-9.9.9
sha="$(shasum -a 256 "$t/Python-9.9.9.tar.xz" | cut -d' ' -f1)"
size="$(wc -c < "$t/Python-9.9.9.tar.xz" | tr -d ' ')"
bad=0000000000000000000000000000000000000000000000000000000000000000

json() { printf '[{"url": "https://www.python.org/ftp/python/9.9.9/Python-9.9.9.tgz", "sha256_sum": "x", "filesize": 1}, {"url": "https://www.python.org/ftp/python/9.9.9/%s", "sha256_sum": "%s", "filesize": %s}]\n' "$1" "$2" "$3" > "$t/api.json"; }
run() { CPYTHON_API_JSON="$t/api.json" CPYTHON_TARBALL="$t/Python-9.9.9.tar.xz" sh "$script" --version 9.9.9 --dest "$t/out" 2>"$t/err"; }

json Python-9.9.9.tar.xz "$sha" "$size"
dir="$(run)" || { echo "FAIL good: $(cat "$t/err")"; exit 1; }
[ -f "$dir/README" ] || { echo "FAIL good: no tree at $dir"; exit 1; }

json Python-9.9.9.tar.xz "$bad" "$size"
if run >/dev/null; then echo "FAIL sha mismatch accepted"; exit 1; fi
grep -q "$bad" "$t/err" && grep -q "$sha" "$t/err" || { echo "FAIL sha mismatch names: $(cat "$t/err")"; exit 1; }

json Python-9.9.8.tar.xz "$sha" "$size"
if run >/dev/null; then echo "FAIL unlisted accepted"; exit 1; fi
grep -q "not listed" "$t/err" || { echo "FAIL unlisted msg: $(cat "$t/err")"; exit 1; }

json Python-9.9.9.tar.xz "$sha" "$((size + 1))"
if run >/dev/null; then echo "FAIL size mismatch accepted"; exit 1; fi

echo "PASS: fetch-cpython"
