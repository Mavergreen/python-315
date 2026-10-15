#!/bin/sh
# platform: host-agnostic
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
MAVERICKS_UPSTREAM_FILE="$MAVERICKS_ROOT/UPSTREAM_VERSION"; export MAVERICKS_UPSTREAM_FILE
. "$SELF/msc.sh"
exec sh "$SHIPYARD/version.sh" "$@"
