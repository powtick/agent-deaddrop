#!/usr/bin/env bash
# A package-affecting change must explicitly change the repository VERSION.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() {
	printf 'check-version-bump: %s\n' "$1" >&2
	exit 1
}

is_version() {
	printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

version_is_greater() {
	local candidate="$1" current="$2" candidate_major candidate_minor candidate_patch current_major current_minor current_patch rest
	candidate_major="${candidate%%.*}"
	rest="${candidate#*.}"
	candidate_minor="${rest%%.*}"
	candidate_patch="${rest#*.}"
	current_major="${current%%.*}"
	rest="${current#*.}"
	current_minor="${rest%%.*}"
	current_patch="${rest#*.}"

	[ "$candidate_major" -gt "$current_major" ] && return 0
	[ "$candidate_major" -lt "$current_major" ] && return 1
	[ "$candidate_minor" -gt "$current_minor" ] && return 0
	[ "$candidate_minor" -lt "$current_minor" ] && return 1
	[ "$candidate_patch" -gt "$current_patch" ]
}

[ "$#" -eq 1 ] || die "usage: scripts/check-version-bump.sh <base-commit>"
BASE="$1"
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null || die "base commit is not available: $BASE (fetch full history)"

if git -C "$ROOT" diff --quiet "$BASE"...HEAD -- bin adapters packaging scripts/package-plugins.sh; then
	printf 'no package-affecting changes since %s\n' "$BASE"
	exit 0
fi

if git -C "$ROOT" diff --quiet "$BASE"...HEAD -- VERSION; then
	die "package inputs changed but VERSION did not; bump VERSION before merging"
fi

"$ROOT/scripts/check-release-tag.sh" "v$(cat "$ROOT/VERSION")" >/dev/null || die "the updated VERSION is invalid"
CURRENT_VERSION="$(cat "$ROOT/VERSION")"
BASE_VERSION="$(git -C "$ROOT" show "$BASE:VERSION" 2>/dev/null || true)"
if [ -n "$BASE_VERSION" ]; then
	is_version "$BASE_VERSION" || die "base commit has invalid VERSION '$BASE_VERSION'"
	version_is_greater "$CURRENT_VERSION" "$BASE_VERSION" ||
		die "VERSION must increase from $BASE_VERSION; current value is $CURRENT_VERSION"
fi
printf 'package changes include an explicit VERSION bump\n'
