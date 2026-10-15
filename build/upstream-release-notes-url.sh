#!/bin/sh
# platform: host-agnostic
set -eu
printf 'https://docs.python.org/release/%s/whatsnew/changelog.html\n' "${1:?usage: upstream-release-notes-url.sh <upstream-version>}"
