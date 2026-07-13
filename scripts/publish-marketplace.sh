#!/usr/bin/env bash
# Publish a validated generated tree to a linear orphan marketplace branch.
# The source repository worktree is used so GitHub checkout credentials carry
# into the publishing worktree without embedding a token in a remote URL.

set -uo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() {
	printf 'publish-marketplace: %s\n' "$1" >&2
	exit 1
}

is_version() {
	printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

version_is_lower() {
	local candidate="$1" current="$2" candidate_major candidate_minor candidate_patch current_major current_minor current_patch rest
	candidate_major="${candidate%%.*}"
	rest="${candidate#*.}"
	candidate_minor="${rest%%.*}"
	candidate_patch="${rest#*.}"
	current_major="${current%%.*}"
	rest="${current#*.}"
	current_minor="${rest%%.*}"
	current_patch="${rest#*.}"

	[ "$candidate_major" -lt "$current_major" ] && return 0
	[ "$candidate_major" -gt "$current_major" ] && return 1
	[ "$candidate_minor" -lt "$current_minor" ] && return 0
	[ "$candidate_minor" -gt "$current_minor" ] && return 1
	[ "$candidate_patch" -lt "$current_patch" ]
}

validate_publish_tree() {
	local package="$1" version symlink entry
	[ -d "$package" ] && [ ! -L "$package" ] || die "package directory does not exist or is a symlink: $package"
	[ -f "$package/VERSION" ] && [ ! -L "$package/VERSION" ] || die "package is missing a regular VERSION file"
	version="$(cat "$package/VERSION")"
	is_version "$version" || die "package VERSION '$version' is not stable semantic version X.Y.Z"
	for entry in "$package"/* "$package"/.[!.]* "$package"/..?*; do
		[ -e "$entry" ] || continue
		case "$(basename "$entry")" in
		VERSION | plugins | .agents | .claude-plugin) ;;
		*) die "package root contains a non-distribution entry: $(basename "$entry")" ;;
		esac
	done
	[ -f "$package/.agents/plugins/marketplace.json" ] || die "package is missing the Codex marketplace catalog"
	[ -f "$package/.claude-plugin/marketplace.json" ] || die "package is missing the Claude marketplace catalog"
	[ -f "$package/plugins/codex/.codex-plugin/plugin.json" ] || die "package is missing the Codex manifest"
	[ -f "$package/plugins/claude-code/.claude-plugin/plugin.json" ] || die "package is missing the Claude manifest"
	[ -x "$package/plugins/codex/bin/deaddrop" ] || die "Codex package binary is missing or not executable"
	[ -x "$package/plugins/claude-code/bin/deaddrop" ] || die "Claude package binary is missing or not executable"
	jq -e --arg version "$version" '.name == "agent-deaddrop" and .version == $version' "$package/plugins/codex/.codex-plugin/plugin.json" >/dev/null 2>&1 ||
		die "Codex manifest does not match package VERSION $version"
	jq -e --arg version "$version" '.name == "agent-deaddrop" and .version == $version' "$package/plugins/claude-code/.claude-plugin/plugin.json" >/dev/null 2>&1 ||
		die "Claude manifest does not match package VERSION $version"
	jq empty "$package/.agents/plugins/marketplace.json" >/dev/null 2>&1 || die "Codex marketplace catalog is invalid JSON"
	jq empty "$package/.claude-plugin/marketplace.json" >/dev/null 2>&1 || die "Claude marketplace catalog is invalid JSON"
	symlink="$(find "$package" -type l -print -quit 2>/dev/null)" || die "cannot inspect package symlinks"
	[ -z "$symlink" ] || die "published package must not contain symlinks: $symlink"
	printf '%s\n' "$version"
}

[ "$#" -ge 1 ] && [ "$#" -le 4 ] || die "usage: scripts/publish-marketplace.sh <package-directory> [branch] [repository] [source-ref]"
PACKAGE_INPUT="$1"
BRANCH="${2:-marketplace}"
REPOSITORY_INPUT="${3:-$SCRIPT_ROOT}"
SOURCE_REF="${4:-$(git -C "$REPOSITORY_INPUT" rev-parse HEAD 2>/dev/null || printf unknown)}"
case "$BRANCH" in
"" | -* | *..* | *[!A-Za-z0-9._/-]*) die "unsafe marketplace branch name: $BRANCH" ;;
esac
PACKAGE="$(cd "$PACKAGE_INPUT" 2>/dev/null && pwd)" || die "cannot resolve package directory: $PACKAGE_INPUT"
VERSION="$(validate_publish_tree "$PACKAGE")" || exit $?
REPOSITORY="$(git -C "$REPOSITORY_INPUT" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository: $REPOSITORY_INPUT"
git -C "$REPOSITORY" remote get-url origin >/dev/null 2>&1 || die "source repository has no origin remote"
[ -z "$(git -C "$REPOSITORY" status --porcelain)" ] || die "source repository is dirty; publish from a clean tagged checkout"

PUBLISH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/deaddrop-publish.XXXXXX")" || die "cannot create publishing directory"
WORKTREE="$PUBLISH_TMP/worktree"
TEMP_BRANCH=""
WORKTREE_ADDED=0
cleanup() {
	if [ "${WORKTREE_ADDED:-0}" -eq 1 ]; then
		git -C "$REPOSITORY" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
	fi
	if [ -n "${TEMP_BRANCH:-}" ]; then
		git -C "$REPOSITORY" branch -D "$TEMP_BRANCH" >/dev/null 2>&1 || true
	fi
	rm -rf "$PUBLISH_TMP"
}
trap cleanup EXIT

REMOTE_STATE=0
git -C "$REPOSITORY" ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >"$PUBLISH_TMP/remote-head" 2>/dev/null
remote_status=$?
case "$remote_status" in
0) REMOTE_STATE=1 ;;
2) REMOTE_STATE=0 ;;
*) die "cannot inspect origin/$BRANCH; verify repository access and the origin remote" ;;
esac

if [ "$REMOTE_STATE" -eq 1 ]; then
	git -C "$REPOSITORY" fetch --quiet --no-tags origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || die "cannot fetch origin/$BRANCH"
	git -C "$REPOSITORY" worktree add --quiet --detach "$WORKTREE" "refs/remotes/origin/$BRANCH" || die "cannot create marketplace worktree"
	WORKTREE_ADDED=1
	[ -f "$WORKTREE/VERSION" ] || die "origin/$BRANCH has no VERSION; inspect the published branch before retrying"
	CURRENT_VERSION="$(cat "$WORKTREE/VERSION")"
	is_version "$CURRENT_VERSION" || die "origin/$BRANCH has invalid VERSION '$CURRENT_VERSION'"
	version_is_lower "$VERSION" "$CURRENT_VERSION" && die "refusing to downgrade marketplace from $CURRENT_VERSION to $VERSION"
else
	git -C "$REPOSITORY" worktree add --quiet --detach "$WORKTREE" HEAD || die "cannot create initial marketplace worktree"
	WORKTREE_ADDED=1
	TEMP_BRANCH="deaddrop-publish-$$"
	git -C "$WORKTREE" checkout --quiet --orphan "$TEMP_BRANCH" || die "cannot create orphan marketplace history"
	CURRENT_VERSION=""
fi

find "$WORKTREE" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + || die "cannot clear marketplace worktree"
cp -R "$PACKAGE/." "$WORKTREE/" || die "cannot copy package into marketplace worktree"
git -C "$WORKTREE" add -A || die "cannot stage marketplace package"

if [ -n "$CURRENT_VERSION" ] && [ "$VERSION" = "$CURRENT_VERSION" ]; then
	if git -C "$WORKTREE" diff --cached --quiet; then
		printf 'marketplace already publishes version %s; no changes\n' "$VERSION"
		exit 0
	fi
	die "marketplace version $VERSION already exists with different contents; bump VERSION"
fi

git -C "$WORKTREE" -c user.name="${GIT_AUTHOR_NAME:-github-actions[bot]}" -c user.email="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
	commit --quiet -m "release: marketplace v$VERSION" -m "Source: $SOURCE_REF" || die "cannot commit marketplace version $VERSION"
git -C "$WORKTREE" push --quiet origin "HEAD:refs/heads/$BRANCH" || die "cannot push origin/$BRANCH without force; fetch and retry"
printf 'published marketplace version %s to origin/%s\n' "$VERSION" "$BRANCH"
