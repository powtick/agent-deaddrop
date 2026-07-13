# shellcheck shell=bash
# Adapter: codex
# Codex transcripts live at ~/.codex/sessions/Y/M/D/rollout-*.jsonl.
# Contract: required sniff + extract; optional title, glob, hook_parse.
# All comments/output English. Extract emits normalized
# {"role":"user|agent","text":"..."} JSONL only; the core renders markdown,
# frontmatter and turn counts.

ADAPTERS="${ADAPTERS:-} codex"

# sniff <file> -> exit 0 if the first record is Codex session metadata.
codex_sniff() {
	head -n 1 -- "$1" 2>/dev/null | jq -e -R '
		(fromjson? // empty)
		| select(
			.type? == "session_meta"
			and (.payload? | type) == "object"
			and (.payload.id? | type) == "string"
			and .payload.id != ""
			and (.payload.cli_version? | type) == "string"
			and .payload.cli_version != ""
		)
	' >/dev/null 2>&1
}

# extract <file> -> normalized {"role","text"} JSONL on stdout.
# Only event_msg records are authoritative. response_item records duplicate
# conversation text and also carry reasoning, tool and injected context data.
codex_extract() {
	jq -c -R '
		(fromjson? // empty) as $l
		| select($l.type? == "event_msg")
		| ($l.payload? // {}) as $p
		| if ($p.type? == "user_message") then
			($p.message? // empty) as $text
			| select(($text | type) == "string" and $text != "")
			| {role: "user", text: $text}
			  elif ($p.type? == "agent_message") then
				select(
					$p.phase? == null
					or $p.phase == "commentary"
					or $p.phase == "final_answer"
			)
			| ($p.message? // empty) as $text
			| select(($text | type) == "string" and $text != "")
			| {role: "agent", text: $text}
		  else
			empty
		  end
	' "$1"
}

# glob -> session-file glob pattern (used by doctor to detect the tool).
codex_glob() {
	printf '%s\n' "$HOME/.codex/sessions/*/*/*/rollout-*.jsonl"
}
