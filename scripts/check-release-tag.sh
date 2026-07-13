#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() {
	printf 'check-release-tag: %s\n' "$1" >&2
	exit 1
}

[ "$#" -eq 1 ] || die "usage: scripts/check-release-tag.sh vX.Y.Z"
[ -f "$ROOT/VERSION" ] || die "missing VERSION; add a single X.Y.Z release version"
[ "$(awk 'END { print NR }' "$ROOT/VERSION")" -eq 1 ] || die "VERSION must contain exactly one X.Y.Z line"
VERSION="$(cat "$ROOT/VERSION")"
printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
	die "invalid VERSION '$VERSION'; use stable semantic version X.Y.Z"
[ "$1" = "v$VERSION" ] || die "tag '$1' does not match VERSION $VERSION; create tag v$VERSION"
printf 'release tag matches VERSION: %s\n' "$1"
