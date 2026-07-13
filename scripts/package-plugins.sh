#!/usr/bin/env bash
# Materialize self-contained agent plugins from canonical sources and packaging
# templates. The generated tree is the only tree published to marketplaces.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="build"

die() {
	printf 'package-plugins: %s\n' "$1" >&2
	exit 1
}

is_version() {
	printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

read_version() {
	local version line_count
	[ -f "$ROOT/VERSION" ] || die "missing VERSION; add a single X.Y.Z release version"
	line_count="$(awk 'END { print NR }' "$ROOT/VERSION")"
	[ "$line_count" -eq 1 ] || die "VERSION must contain exactly one X.Y.Z line"
	version="$(cat "$ROOT/VERSION")"
	is_version "$version" || die "invalid VERSION '$version'; use stable semantic version X.Y.Z"
	printf '%s\n' "$version"
}

require_regular_file() {
	local path="$1" label="$2"
	if [ ! -f "$path" ] || [ -L "$path" ]; then
		die "$label must be a regular file: $path"
	fi
}

find_manifest() {
	local plugin_root="$1" manifests count
	manifests="$(find "$plugin_root" -mindepth 2 -maxdepth 2 -type f -name plugin.json -print 2>/dev/null)" ||
		die "cannot inspect plugin manifests under $plugin_root"
	count="$(printf '%s\n' "$manifests" | sed '/^$/d' | wc -l | tr -d ' ')"
	[ "$count" -eq 1 ] || die "expected exactly one plugin manifest under $plugin_root, found $count"
	printf '%s\n' "$manifests"
}

validate_package() {
	local output="$1" version="$2" symlink plugin_root tool manifest found json_file adapter_count

	if [ ! -d "$output" ] || [ -L "$output" ]; then
		die "package output is not a regular directory: $output"
	fi
	require_regular_file "$output/VERSION" "package VERSION"
	[ "$(cat "$output/VERSION")" = "$version" ] || die "package VERSION does not match source VERSION $version"
	require_regular_file "$output/.agents/plugins/marketplace.json" "Codex marketplace catalog"
	require_regular_file "$output/.claude-plugin/marketplace.json" "Claude marketplace catalog"

	symlink="$(find "$output" -type l -print -quit 2>/dev/null)" || die "cannot inspect package symlinks: $output"
	[ -z "$symlink" ] || die "generated packages must not contain symlinks: $symlink"

	while IFS= read -r json_file; do
		jq empty "$json_file" >/dev/null 2>&1 || die "invalid generated JSON: $json_file"
	done < <(find "$output" -type f -name '*.json' -print)

	found=0
	for plugin_root in "$ROOT"/packaging/plugins/*; do
		[ -d "$plugin_root" ] || continue
		found=1
		tool="$(basename "$plugin_root")"
		plugin_root="$output/plugins/$tool"
		manifest="$(find_manifest "$plugin_root")" || exit $?

		require_regular_file "$plugin_root/hooks/hooks.json" "plugin hook configuration"
		require_regular_file "$plugin_root/bin/deaddrop" "plugin binary"
		require_regular_file "$plugin_root/adapters/$tool.sh" "plugin adapter"
		[ -x "$plugin_root/bin/deaddrop" ] || die "plugin binary is not executable: $plugin_root/bin/deaddrop"
		cmp -s "$ROOT/bin/deaddrop" "$plugin_root/bin/deaddrop" || die "generated plugin binary differs from canonical bin/deaddrop"
		cmp -s "$ROOT/adapters/$tool.sh" "$plugin_root/adapters/$tool.sh" || die "generated $tool adapter differs from its canonical source"
		jq -e --arg version "$version" '.name == "agent-deaddrop" and .version == $version' "$manifest" >/dev/null 2>&1 ||
			die "generated manifest has the wrong name or version: $manifest"
		adapter_count="$(find "$plugin_root/adapters" -type f -name '*.sh' | wc -l | tr -d ' ')"
		[ "$adapter_count" -eq 1 ] || die "plugin $tool must contain only its own adapter"
	done
	[ "$found" -eq 1 ] || die "no plugin templates found under packaging/plugins"

	jq -e '
		.name == "agent-deaddrop"
		and .plugins[0].name == "agent-deaddrop"
		and .plugins[0].source.source == "local"
		and .plugins[0].source.path == "./plugins/codex"
		and .plugins[0].policy.installation == "AVAILABLE"
		and .plugins[0].policy.authentication == "ON_INSTALL"
		and .plugins[0].category == "Productivity"
	' "$output/.agents/plugins/marketplace.json" >/dev/null 2>&1 || die "invalid Codex marketplace catalog"
	jq -e '
		.name == "agent-deaddrop"
		and .plugins[0].name == "agent-deaddrop"
		and .plugins[0].source == "./plugins/claude-code"
	' "$output/.claude-plugin/marketplace.json" >/dev/null 2>&1 || die "invalid Claude marketplace catalog"
	jq -e 'has("hooks") | not' "$output/plugins/codex/.codex-plugin/plugin.json" >/dev/null 2>&1 ||
		die "Codex manifest must rely on default hooks/hooks.json discovery"
	if grep -R '\[TODO:' "$output" >/dev/null 2>&1; then
		die "generated package contains an unresolved TODO placeholder"
	fi
}

atomic_set_version() {
	local manifest="$1" version="$2" tmp
	tmp="$(mktemp "${manifest}.XXXXXX")" || die "mktemp failed for $manifest"
	if ! jq --arg version "$version" '.version = $version' "$manifest" >"$tmp"; then
		rm -f "$tmp"
		die "cannot inject version into $manifest"
	fi
	chmod 0644 "$tmp" || {
		rm -f "$tmp"
		die "cannot set manifest permissions: $manifest"
	}
	mv -f "$tmp" "$manifest" || die "cannot replace generated manifest: $manifest"
}

if [ "${1:-}" = "--check" ]; then
	MODE="check"
	shift
fi
[ "$#" -le 1 ] || die "usage: scripts/package-plugins.sh [--check] [output-directory]"

VERSION="$(read_version)" || exit $?
OUTPUT_INPUT="${1:-$ROOT/.dist/marketplace}"
OUTPUT_PARENT="$(dirname "$OUTPUT_INPUT")"
OUTPUT_BASE="$(basename "$OUTPUT_INPUT")"
case "$OUTPUT_BASE" in
"" | . | /) die "unsafe output directory: $OUTPUT_INPUT" ;;
esac
mkdir -p "$OUTPUT_PARENT" || die "cannot create output parent: $OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd)" || die "cannot resolve output parent: $OUTPUT_PARENT"
OUTPUT="$OUTPUT_PARENT/$OUTPUT_BASE"
[ "$OUTPUT" != "$ROOT" ] || die "output directory must not replace the repository root"

if [ "$MODE" = "check" ]; then
	validate_package "$OUTPUT" "$VERSION"
	printf 'package valid: %s\n' "$OUTPUT"
	exit 0
fi

STAGE="$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_BASE}.tmp.XXXXXX")" || die "cannot create package staging directory"
BACKUP=""
cleanup() {
	[ -z "${STAGE:-}" ] || [ ! -e "$STAGE" ] || rm -rf "$STAGE"
	[ -z "${BACKUP:-}" ] || [ ! -e "$BACKUP" ] || rm -rf "$BACKUP"
}
trap cleanup EXIT

cp -R "$ROOT/packaging/." "$STAGE/" || die "cannot copy packaging templates"
printf '%s\n' "$VERSION" >"$STAGE/VERSION" || die "cannot write generated VERSION"

found=0
for template_root in "$ROOT"/packaging/plugins/*; do
	[ -d "$template_root" ] || continue
	found=1
	tool="$(basename "$template_root")"
	plugin_root="$STAGE/plugins/$tool"
	[ -f "$ROOT/adapters/$tool.sh" ] || die "missing canonical adapter: adapters/$tool.sh"
	mkdir -p "$plugin_root/bin" "$plugin_root/adapters" || die "cannot create payload directories for $tool"
	cp "$ROOT/bin/deaddrop" "$plugin_root/bin/deaddrop" || die "cannot copy canonical binary for $tool"
	cp "$ROOT/adapters/$tool.sh" "$plugin_root/adapters/$tool.sh" || die "cannot copy canonical adapter for $tool"
	chmod 0755 "$plugin_root/bin/deaddrop" || die "cannot make generated binary executable for $tool"
	chmod 0644 "$plugin_root/adapters/$tool.sh" || die "cannot set generated adapter permissions for $tool"
	manifest="$(find_manifest "$plugin_root")" || exit $?
	atomic_set_version "$manifest" "$VERSION"
done
[ "$found" -eq 1 ] || die "no plugin templates found under packaging/plugins"

validate_package "$STAGE" "$VERSION"

if [ -e "$OUTPUT" ]; then
	[ -d "$OUTPUT" ] || die "refusing to replace a non-directory output: $OUTPUT"
	if [ ! -f "$OUTPUT/VERSION" ] || [ ! -f "$OUTPUT/.agents/plugins/marketplace.json" ] || [ ! -f "$OUTPUT/.claude-plugin/marketplace.json" ]; then
		die "refusing to replace a directory that is not a generated marketplace: $OUTPUT"
	fi
	BACKUP="$OUTPUT_PARENT/.${OUTPUT_BASE}.old.$$"
	[ ! -e "$BACKUP" ] || die "temporary backup path already exists: $BACKUP"
	mv "$OUTPUT" "$BACKUP" || die "cannot move the previous generated package aside"
fi
if ! mv "$STAGE" "$OUTPUT"; then
	[ -z "$BACKUP" ] || mv "$BACKUP" "$OUTPUT" >/dev/null 2>&1
	die "cannot install generated package at $OUTPUT"
fi
STAGE=""
[ -z "$BACKUP" ] || rm -rf "$BACKUP"
BACKUP=""
printf 'packaged plugins: %s (version %s)\n' "$OUTPUT" "$VERSION"
