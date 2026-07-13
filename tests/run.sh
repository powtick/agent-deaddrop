#!/usr/bin/env bash
#
# deaddrop test runner. Pure bash assertions, no framework.
# Covers: adapter extraction (diff vs expected, auto-traversing tests/fixtures),
# drop (full + turns), rename-to-.bak, auto-naming, pickup (name/list/index/page),
# generated self-contained plugin payloads, version/release gates, the
# hook-prompt sentinel path, and the adapter-guard message.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEADDROP="$ROOT/bin/deaddrop"
PLUGIN_VERSION="$(cat "$ROOT/VERSION")"

fail=0
report() {
	if [ "$1" -eq 0 ]; then
		printf 'PASS  %s\n' "$2"
	else
		printf 'FAIL  %s\n' "$2"
		fail=1
	fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export DEADDROP_DIR="$tmp/dd"

PACKAGE_ROOT="$tmp/marketplace"
PACKAGE_ROOT_2="$tmp/marketplace-again"
if "$ROOT/scripts/package-plugins.sh" "$PACKAGE_ROOT" >/dev/null 2>&1 &&
	"$ROOT/scripts/package-plugins.sh" --check "$PACKAGE_ROOT" >/dev/null 2>&1; then
	report 0 "plugin marketplace builds and validates from canonical sources"
else
	report 1 "plugin marketplace builds and validates from canonical sources"
	printf 'cannot continue without generated plugin packages\n' >&2
	exit 1
fi
CLAUDE_PLUGIN="$PACKAGE_ROOT/plugins/claude-code"
CODEX_PLUGIN="$PACKAGE_ROOT/plugins/codex"

"$ROOT/scripts/package-plugins.sh" "$PACKAGE_ROOT_2" >/dev/null 2>&1
if diff -qr "$PACKAGE_ROOT" "$PACKAGE_ROOT_2" >/dev/null 2>&1; then
	report 0 "plugin packaging is reproducible"
else
	report 1 "plugin packaging is reproducible"
fi

if [ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" ] &&
	cmp -s "$ROOT/bin/deaddrop" "$CLAUDE_PLUGIN/bin/deaddrop" &&
	cmp -s "$ROOT/bin/deaddrop" "$CODEX_PLUGIN/bin/deaddrop" &&
	cmp -s "$ROOT/adapters/claude-code.sh" "$CLAUDE_PLUGIN/adapters/claude-code.sh" &&
	cmp -s "$ROOT/adapters/codex.sh" "$CODEX_PLUGIN/adapters/codex.sh" &&
	[ ! -e "$CLAUDE_PLUGIN/adapters/codex.sh" ] &&
	[ ! -e "$CODEX_PLUGIN/adapters/claude-code.sh" ]; then
	report 0 "generated plugins contain real canonical payloads and only their own adapter"
else
	report 1 "generated plugins contain real canonical payloads and only their own adapter"
fi

if "$ROOT/scripts/check-release-tag.sh" "v$PLUGIN_VERSION" >/dev/null 2>&1 &&
	! "$ROOT/scripts/check-release-tag.sh" "v999.999.999" >/dev/null 2>&1 &&
	! "$ROOT/scripts/check-release-tag.sh" "$PLUGIN_VERSION" >/dev/null 2>&1; then
	report 0 "release tags must exactly match vVERSION"
else
	report 1 "release tags must exactly match vVERSION"
fi

# Exercise the PR version policy inside an isolated git repository.
version_repo="$tmp/version-policy"
mkdir -p "$version_repo/scripts" "$version_repo/bin" "$version_repo/docs"
cp "$ROOT/scripts/check-version-bump.sh" "$ROOT/scripts/check-release-tag.sh" "$version_repo/scripts/"
chmod +x "$version_repo/scripts/"*.sh
printf '0.0.1\n' >"$version_repo/VERSION"
printf 'core\n' >"$version_repo/bin/deaddrop"
printf 'docs\n' >"$version_repo/docs/readme.md"
git -C "$version_repo" init -q
git -C "$version_repo" config user.name test
git -C "$version_repo" config user.email test@example.com
git -C "$version_repo" add .
git -C "$version_repo" commit -qm base
version_base="$(git -C "$version_repo" rev-parse HEAD)"
printf 'pre-release package change\n' >>"$version_repo/bin/deaddrop"
git -C "$version_repo" add bin/deaddrop
git -C "$version_repo" commit -qm pre-release-package-change
"$version_repo/scripts/check-version-bump.sh" "$version_base" >/dev/null 2>&1
report $? "an untagged release candidate can be fixed without changing VERSION"
git -C "$version_repo" tag v0.0.1
version_base="$(git -C "$version_repo" rev-parse HEAD)"
printf 'docs only\n' >>"$version_repo/docs/readme.md"
git -C "$version_repo" add docs/readme.md
git -C "$version_repo" commit -qm docs
"$version_repo/scripts/check-version-bump.sh" "$version_base" >/dev/null 2>&1
report $? "documentation-only changes do not require a plugin version bump"
version_base="$(git -C "$version_repo" rev-parse HEAD)"
printf 'package change\n' >>"$version_repo/bin/deaddrop"
git -C "$version_repo" add bin/deaddrop
git -C "$version_repo" commit -qm package-change
if "$version_repo/scripts/check-version-bump.sh" "$version_base" >/dev/null 2>&1; then
	report 1 "package changes without a VERSION bump are rejected"
else
	report 0 "package changes without a VERSION bump are rejected"
fi
printf '0.0.2\n' >"$version_repo/VERSION"
git -C "$version_repo" add VERSION
git -C "$version_repo" commit -qm version-bump
"$version_repo/scripts/check-version-bump.sh" "$version_base" >/dev/null 2>&1
report $? "package changes with an explicit VERSION bump pass"
version_base="$(git -C "$version_repo" rev-parse HEAD)"
printf 'another package change\n' >>"$version_repo/bin/deaddrop"
printf '0.0.1\n' >"$version_repo/VERSION"
git -C "$version_repo" add bin/deaddrop VERSION
git -C "$version_repo" commit -qm version-downgrade
if "$version_repo/scripts/check-version-bump.sh" "$version_base" >/dev/null 2>&1; then
	report 1 "a VERSION bump must increase the semantic version"
else
	report 0 "a VERSION bump must increase the semantic version"
fi

fix="$ROOT/tests/fixtures/claude-code/sample.jsonl"
codex_fix="$ROOT/tests/fixtures/codex/sample.jsonl"
proj="$tmp/myproj"
mkdir -p "$proj"

# --- 1. Adapter extraction: diff actual vs expected for every fixture --------
for fixdir in "$ROOT"/tests/fixtures/*/; do
	tool="$(basename "$fixdir")"
	for f in "$fixdir"*.jsonl; do
		[ -e "$f" ] || continue
		base="$(basename "$f")"
		exp="$ROOT/tests/expected/$tool/$base"
		got="$("$DEADDROP" _extract "$tool" "$f")"
		if diff <(printf '%s\n' "$got") "$exp" >/dev/null 2>&1; then
			report 0 "extract $tool/$base"
		else
			report 1 "extract $tool/$base"
			diff <(printf '%s\n' "$got") "$exp" | sed 's/^/      /'
		fi
	done
done

# --- 2. drop (full): file, headings, counts, scope, .bak --------------------
df="$tmp/dd/drops/myproj/note1.md"
(cd "$proj" && "$DEADDROP" drop "$fix" note1 >/dev/null)
if [ -f "$df" ]; then
	status=0
else
	status=1
fi
report "$status" "drop creates the drop file"
grep -q '^## User' "$df"
report $? "drop renders a User heading"
grep -q '美光同样在扩产' "$df"
report $? "drop body contains extracted agent text"
grep -q '^turns_user: 2' "$df"
report $? "drop frontmatter counts user turns"
grep -q '^scope: full' "$df"
report $? "full drop is marked scope: full"
(cd "$proj" && "$DEADDROP" drop "$fix" note1 >/dev/null)
if [ -f "$df.bak" ]; then
	status=0
else
	status=1
fi
report "$status" "re-dropping the same name moves the old file to .bak"

# --- 3. drop turns: 0 = last answer; N = last N rounds ----------------------
c0="$tmp/dd/drops/myproj/concl0.md"
(cd "$proj" && "$DEADDROP" drop "$fix" concl0 0 >/dev/null)
grep -q '^scope: 0' "$c0"
report $? "drop <path> <name> 0 is marked scope: 0"
grep -q '^turns_user: 0' "$c0" && grep -q '^turns_agent: 1' "$c0"
report $? "turns 0 keeps exactly one agent turn, no user turns"
grep -q '美光同样在扩产' "$c0" && ! grep -q 'SK hynix' "$c0"
report $? "turns 0 keeps only the final agent answer"

c1="$tmp/dd/drops/myproj/concl1.md"
(cd "$proj" && "$DEADDROP" drop "$fix" concl1 1 >/dev/null)
grep -q '^turns_user: 1' "$c1" && grep -q '^turns_agent: 1' "$c1"
report $? "turns 1 keeps the last round (one q + one a)"
grep -q '第二个问题' "$c1" && ! grep -q 'hynix 的 HBM 产能' "$c1"
report $? "turns 1 keeps the last user question, drops earlier ones"

c2="$tmp/dd/drops/myproj/concl2.md"
(cd "$proj" && "$DEADDROP" drop "$fix" concl2 2 >/dev/null)
grep -q '^turns_user: 2' "$c2" && grep -q '^turns_agent: 2' "$c2"
report $? "turns 2 keeps the last two rounds"

# --- 4. auto-naming: <agent>-<title 10 chars>-<scope>-<timestamp> -----------
(cd "$proj" && "$DEADDROP" drop "$fix" >/dev/null)
ls "$tmp"/dd/drops/myproj/claude-code-conversati-full-*.md >/dev/null 2>&1
report $? "auto-name is <agent>-<title 10 chars>-<scope>-<timestamp>"

# Codex metadata uses session_meta.payload.id rather than Claude's sessionId.
codex_df="$tmp/dd/drops/myproj/codex-note.md"
(cd "$proj" && "$DEADDROP" drop "$codex_fix" codex-note >/dev/null)
grep -q '^source_tool: codex' "$codex_df" &&
	grep -q '^session_id: 0190abcd-1234-7000-8000-000000000001' "$codex_df"
report $? "Codex drop records its adapter and session id"
grep -q '^turns_user: 2' "$codex_df" && grep -q '^turns_agent: 5' "$codex_df"
report $? "Codex drop counts only normalized visible messages"

# --- 5. pickup: name, miss, table, index ------------------------------------
out="$(cd "$proj" && "$DEADDROP" pickup note1)"
printf '%s' "$out" | grep -q '^## User'
report $? "pickup <name> prints the drop body"
if (cd "$proj" && "$DEADDROP" pickup no-such) >/dev/null 2>&1; then
	report 1 "pickup miss exits non-zero"
else
	report 0 "pickup miss exits non-zero"
fi
list_out="$(cd "$proj" && "$DEADDROP" pickup 2>&1)"
printf '%s' "$list_out" | grep -q 'note1'
report $? "pickup with no name lists drops"
printf '%s' "$list_out" | grep -q 'agent' && printf '%s' "$list_out" | grep -q 'turns'
report $? "pickup list is a table with agent/turns columns"
idx_out="$(cd "$proj" && "$DEADDROP" pickup 1)"
printf '%s' "$idx_out" | grep -q '^## '
report $? "pickup <index> selects a drop by list position"

# pagination: page 1 footer, --page 2 second page, --all no footer.
cap_out="$(cd "$proj" && DEADDROP_LIST_LIMIT=2 "$DEADDROP" pickup 2>&1)"
printf '%s' "$cap_out" | grep -q 'page 1/'
report $? "pickup paginates with a 'page 1/N' footer"
p2_out="$(cd "$proj" && DEADDROP_LIST_LIMIT=2 "$DEADDROP" pickup --page 2 2>&1)"
printf '%s' "$p2_out" | grep -q 'page 2/'
report $? "pickup --page 2 shows the second page"
all_out="$(cd "$proj" && DEADDROP_LIST_LIMIT=2 "$DEADDROP" pickup --all 2>&1)"
if printf '%s' "$all_out" | grep -q '^(page '; then
	report 1 "pickup --all shows everything (no page footer)"
else
	report 0 "pickup --all shows everything (no page footer)"
fi

# --- 6. pickup --copy routes to clipboard (fake tool; no real clobber) -------
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
printf '#!/bin/sh\ncat >/dev/null\n' >"$fakebin/pbcopy"
chmod +x "$fakebin/pbcopy"
copy_out="$(cd "$proj" && PATH="$fakebin:$PATH" "$DEADDROP" pickup note1 --copy 2>&1)"
printf '%s' "$copy_out" | grep -q 'paste'
report $? "pickup --copy routes to the clipboard with a confirmation"

# --- 7. hook-prompt: sentinel blocks + acts; non-sentinel passes through -----
payload="$(jq -n --arg tp "$fix" --arg c "$proj" '{user_prompt: ">>drop hooktest", transcript_path: $tp, cwd: $c}')"
hp="$(printf '%s' "$payload" | "$CLAUDE_PLUGIN/bin/deaddrop" hook-prompt --tool claude-code)"
printf '%s' "$hp" | jq -e '.decision == "block"' >/dev/null 2>&1
report $? "hook-prompt blocks the sentinel prompt"
printf '%s' "$hp" | jq -r '.reason' | grep -q 'dropped as'
report $? "hook-prompt returns the drop result as the block reason"
if [ -f "$tmp/dd/drops/myproj/hooktest.md" ]; then
	status=0
else
	status=1
fi
report "$status" "hook-prompt actually performed the drop"
pass_payload="$(jq -n '{user_prompt: "hello world", transcript_path: "x", cwd: "/tmp"}')"
pass_out="$(printf '%s' "$pass_payload" | "$CLAUDE_PLUGIN/bin/deaddrop" hook-prompt --tool claude-code)"
if [ -z "$pass_out" ]; then
	status=0
else
	status=1
fi
report "$status" "hook-prompt ignores non-sentinel prompts (they reach the model)"
sp_payload="$(jq -n --arg tp "$fix" --arg c "$proj" '{user_prompt: ">> drop spaced", transcript_path: $tp, cwd: $c}')"
printf '%s' "$sp_payload" | "$CLAUDE_PLUGIN/bin/deaddrop" hook-prompt --tool claude-code >/dev/null
if [ -f "$tmp/dd/drops/myproj/spaced.md" ]; then
	status=0
else
	status=1
fi
report "$status" "hook-prompt tolerates a space after >> (\">> drop\")"

codex_payload="$(jq -n --arg tp "$codex_fix" --arg c "$proj" '{
	session_id: "codex-session", turn_id: "codex-turn",
	prompt: ">>drop codexhook", transcript_path: $tp, cwd: $c,
	hook_event_name: "UserPromptSubmit", model: "gpt-test",
	permission_mode: "default"
}')"
codex_hook_cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CODEX_PLUGIN/hooks/hooks.json")"
codex_hp="$(printf '%s' "$codex_payload" | PLUGIN_ROOT="$CODEX_PLUGIN" /bin/sh -c "$codex_hook_cmd")"
printf '%s' "$codex_hp" | jq -e '.decision == "block" and (.reason | contains("dropped as"))' >/dev/null 2>&1
report $? "Codex plugin hook routes prompt payloads and blocks sentinels"
[ -f "$tmp/dd/drops/myproj/codexhook.md" ] && grep -q '^source_tool: codex' "$tmp/dd/drops/myproj/codexhook.md"
report $? "Codex plugin hook drops the current rollout with the Codex adapter"
codex_pass="$(printf '%s' "${codex_payload/>>drop codexhook/ordinary prompt}" | "$CODEX_PLUGIN/bin/deaddrop" hook-prompt --tool codex)"
if [ -z "$codex_pass" ]; then
	status=0
else
	status=1
fi
report "$status" "Codex hook ignores non-sentinel prompts"
codex_null_payload="$(printf '%s' "$codex_payload" | jq '.transcript_path = null | .prompt = ">>drop"')"
codex_null_hp="$(printf '%s' "$codex_null_payload" | "$CODEX_PLUGIN/bin/deaddrop" hook-prompt --tool codex)"
printf '%s' "$codex_null_hp" | jq -r '.reason' | grep -q 'persisted local session'
report $? "Codex hook explains how to recover when no transcript is persisted"
if "$CLAUDE_PLUGIN/bin/deaddrop" hook-prompt --tool </dev/null >/dev/null 2>&1; then
	report 1 "hook-prompt rejects a missing --tool value"
else
	report 0 "hook-prompt rejects a missing --tool value"
fi

jq -e --arg version "$PLUGIN_VERSION" '
	.name == "agent-deaddrop"
	and .version == $version
	and .interface.displayName == "Agent Dead Drop"
	and (has("hooks") | not)
' "$CODEX_PLUGIN/.codex-plugin/plugin.json" >/dev/null 2>&1 &&
	jq -e '
		.name == "agent-deaddrop"
		and .plugins[0].name == "agent-deaddrop"
		and .plugins[0].source.source == "local"
		and .plugins[0].source.path == "./plugins/codex"
		and .plugins[0].policy.installation == "AVAILABLE"
		and .plugins[0].policy.authentication == "ON_INSTALL"
		and .plugins[0].category == "Productivity"
	' "$PACKAGE_ROOT/.agents/plugins/marketplace.json" >/dev/null 2>&1 &&
	jq -e '
		.name == "agent-deaddrop"
		and .plugins[0].name == "agent-deaddrop"
		and .plugins[0].source == "./plugins/claude-code"
	' "$PACKAGE_ROOT/.claude-plugin/marketplace.json" >/dev/null 2>&1 &&
	jq -e --arg version "$PLUGIN_VERSION" '.name == "agent-deaddrop" and .version == $version' "$CLAUDE_PLUGIN/.claude-plugin/plugin.json" >/dev/null 2>&1 &&
	jq -e '
		.hooks.UserPromptSubmit[0].hooks[0].timeout == 30
		and (.hooks.UserPromptSubmit[0].hooks[0].command | contains("--tool codex"))
	' "$CODEX_PLUGIN/hooks/hooks.json" >/dev/null 2>&1 &&
	jq -e '
		.hooks.UserPromptSubmit[0].hooks[0]
		| .command == "${CLAUDE_PLUGIN_ROOT}/bin/deaddrop"
		and .args == ["hook-prompt", "--tool", "claude-code"]
	' "$CLAUDE_PLUGIN/hooks/hooks.json" >/dev/null 2>&1
report $? "Claude and Codex plugin packages are independent and self-contained"

# --- 8. release publishing: orphan first publish, idempotency, linear update -
publish_remote="$tmp/publish-remote.git"
publish_source="$tmp/publish-source"
git init -q --bare "$publish_remote"
git init -q "$publish_source"
git -C "$publish_source" config user.name test
git -C "$publish_source" config user.email test@example.com
printf 'source\n' >"$publish_source/README.md"
git -C "$publish_source" add README.md
git -C "$publish_source" commit -qm source
git -C "$publish_source" branch -M main
git -C "$publish_source" remote add origin "$publish_remote"
git -C "$publish_source" push -q -u origin main

"$ROOT/scripts/publish-marketplace.sh" "$PACKAGE_ROOT" marketplace "$publish_source" "v$PLUGIN_VERSION" >/dev/null 2>&1
publish_status=$?
root_fields="$(git --git-dir="$publish_remote" rev-list --parents --max-count=1 refs/heads/marketplace 2>/dev/null | awk '{ print NF }')"
if [ "$publish_status" -eq 0 ] && [ "$root_fields" -eq 1 ] &&
	! git --git-dir="$publish_remote" merge-base refs/heads/main refs/heads/marketplace >/dev/null 2>&1; then
	report 0 "first publish creates an orphan marketplace branch"
else
	report 1 "first publish creates an orphan marketplace branch"
fi

published_clone="$tmp/published-clone"
git clone -q --branch marketplace "$publish_remote" "$published_clone"
rm -rf "$published_clone/.git"
if diff -qr "$PACKAGE_ROOT" "$published_clone" >/dev/null 2>&1; then
	report 0 "published branch contains exactly the generated marketplace tree"
else
	report 1 "published branch contains exactly the generated marketplace tree"
fi

commit_count_before="$(git --git-dir="$publish_remote" rev-list --count refs/heads/marketplace)"
"$ROOT/scripts/publish-marketplace.sh" "$PACKAGE_ROOT" marketplace "$publish_source" "v$PLUGIN_VERSION" >/dev/null 2>&1
repeat_status=$?
commit_count_after="$(git --git-dir="$publish_remote" rev-list --count refs/heads/marketplace)"
if [ "$repeat_status" -eq 0 ] && [ "$commit_count_before" -eq "$commit_count_after" ]; then
	report 0 "re-publishing identical contents is an idempotent no-op"
else
	report 1 "re-publishing identical contents is an idempotent no-op"
fi

version_major="${PLUGIN_VERSION%%.*}"
version_rest="${PLUGIN_VERSION#*.}"
version_minor="${version_rest%%.*}"
version_patch="${version_rest#*.}"
NEXT_VERSION="$version_major.$version_minor.$((version_patch + 1))"
next_package="$tmp/marketplace-next"
mkdir -p "$next_package"
cp -R "$PACKAGE_ROOT/." "$next_package/"
printf '%s\n' "$NEXT_VERSION" >"$next_package/VERSION"
for manifest in \
	"$next_package/plugins/claude-code/.claude-plugin/plugin.json" \
	"$next_package/plugins/codex/.codex-plugin/plugin.json"; do
	jq --arg version "$NEXT_VERSION" '.version = $version' "$manifest" >"$manifest.next"
	mv "$manifest.next" "$manifest"
done
"$ROOT/scripts/publish-marketplace.sh" "$next_package" marketplace "$publish_source" "v$NEXT_VERSION" >/dev/null 2>&1
next_status=$?
next_count="$(git --git-dir="$publish_remote" rev-list --count refs/heads/marketplace)"
if [ "$next_status" -eq 0 ] && [ "$next_count" -eq 2 ] &&
	[ "$(git --git-dir="$publish_remote" show refs/heads/marketplace:VERSION)" = "$NEXT_VERSION" ]; then
	report 0 "a higher version appends one linear marketplace commit"
else
	report 1 "a higher version appends one linear marketplace commit"
fi

if "$ROOT/scripts/publish-marketplace.sh" "$PACKAGE_ROOT" marketplace "$publish_source" "v$PLUGIN_VERSION" >/dev/null 2>&1; then
	report 1 "marketplace publishing rejects version downgrades"
else
	report 0 "marketplace publishing rejects version downgrades"
fi

# --- 9. adapter guard: incomplete adapter disabled with a message -----------
mkdir -p "$tmp/dd/adapters.d"
# shellcheck disable=SC2016 # The fixture must preserve parameter expansion.
printf 'ADAPTERS="${ADAPTERS:-} broken"\nbroken_sniff() { return 1; }\n' \
	>"$tmp/dd/adapters.d/broken.sh"
guard_err="$("$DEADDROP" list 2>&1 >/dev/null)"
printf '%s' "$guard_err" | grep -q 'adapter "broken" disabled'
report $? "incomplete adapter is disabled with a clear message"

# --- summary ----------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
	printf '\nall green\n'
else
	printf '\nFAILURES above\n'
	exit 1
fi
