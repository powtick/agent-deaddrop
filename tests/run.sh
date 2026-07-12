#!/usr/bin/env bash
#
# deaddrop test runner. Pure bash assertions, no framework.
# Covers: adapter extraction (diff vs expected, auto-traversing tests/fixtures),
# drop (full + turns), rename-to-.bak, auto-naming, pickup (name/list/index/page),
# the hook-prompt sentinel path, and the adapter-guard message.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEADDROP="$ROOT/bin/deaddrop"

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

fix="$ROOT/tests/fixtures/claude-code/sample.jsonl"
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
[ -f "$df" ]
report $? "drop creates the drop file"
grep -q '^## User' "$df"
report $? "drop renders a User heading"
grep -q '美光同样在扩产' "$df"
report $? "drop body contains extracted agent text"
grep -q '^turns_user: 2' "$df"
report $? "drop frontmatter counts user turns"
grep -q '^scope: full' "$df"
report $? "full drop is marked scope: full"
(cd "$proj" && "$DEADDROP" drop "$fix" note1 >/dev/null)
[ -f "$df.bak" ]
report $? "re-dropping the same name moves the old file to .bak"

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
hp="$(printf '%s' "$payload" | "$DEADDROP" hook-prompt --tool claude-code)"
printf '%s' "$hp" | jq -e '.decision == "block"' >/dev/null 2>&1
report $? "hook-prompt blocks the sentinel prompt"
printf '%s' "$hp" | jq -r '.reason' | grep -q 'dropped as'
report $? "hook-prompt returns the drop result as the block reason"
[ -f "$tmp/dd/drops/myproj/hooktest.md" ]
report $? "hook-prompt actually performed the drop"
pass_payload="$(jq -n '{user_prompt: "hello world", transcript_path: "x", cwd: "/tmp"}')"
pass_out="$(printf '%s' "$pass_payload" | "$DEADDROP" hook-prompt --tool claude-code)"
[ -z "$pass_out" ]
report $? "hook-prompt ignores non-sentinel prompts (they reach the model)"
sp_payload="$(jq -n --arg tp "$fix" --arg c "$proj" '{user_prompt: ">> drop spaced", transcript_path: $tp, cwd: $c}')"
printf '%s' "$sp_payload" | "$DEADDROP" hook-prompt --tool claude-code >/dev/null
[ -f "$tmp/dd/drops/myproj/spaced.md" ]
report $? "hook-prompt tolerates a space after >> (\">> drop\")"

# --- 8. adapter guard: incomplete adapter disabled with a message -----------
mkdir -p "$tmp/dd/adapters.d"
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
