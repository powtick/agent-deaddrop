# Adapter: claude-code
# Claude Code transcripts live at ~/.claude/projects/<escaped-cwd>/<uuid>.jsonl.
# Contract: required sniff + extract; optional title, glob, hook_parse.
# All comments/output English. Extract emits normalized
# {"role":"user|agent","text":"..."} JSONL only; the core renders markdown,
# frontmatter and turn counts.

ADAPTERS="${ADAPTERS:-} claude-code"

# sniff <file> -> exit 0 if this looks like a Claude Code transcript.
claude_code_sniff() {
	head -n 50 -- "$1" 2>/dev/null | jq -e -R '
		(fromjson? // empty)
		| select(
			(.type? == "user" or .type? == "assistant" or .type? == "summary")
			and (has("uuid") or has("sessionId") or has("cwd"))
		)
	' >/dev/null 2>&1
}

# extract <file> -> normalized {"role","text"} JSONL on stdout.
# Rules (DESIGN.md 6.3):
#   user: type=="user"; string content used as-is, array content keeps only
#         text blocks. Drop isMeta, tool_result-only, and injected strings
#         (<command-, <local-command, <system-reminder, Caveat: The messages below).
#   agent: type=="assistant"; keep text blocks only (drop thinking / tool_use).
claude_code_extract() {
	jq -c -R '
		(fromjson? // empty) as $l
		| if ($l.type == "user") then
			( if (($l.isMeta // false) == true) then empty
			  else
				( ($l.message.content) as $c
				  | ( if (($c | type) == "string")
					  then $c
					  else ([ $c[]? | select(.type? == "text") | .text ] | join("\n"))
					  end
					)
				) as $text
				| select(($text | type) == "string")
				| select($text != "")
				| select(($text | test("^(<command-|<local-command|<system-reminder|Caveat: The messages below)")) | not)
				| {role: "user", text: $text}
			  end
			)
		  elif ($l.type == "assistant") then
			( [ $l.message.content[]? | select(.type? == "text") | .text ] | join("\n") ) as $text
			| select($text != "")
			| {role: "agent", text: $text}
		  else
			empty
		  end
	' "$1"
}

# title <file> -> a short human title for the session (optional function).
# Uses the transcript's own summary line (the title Claude shows in /resume),
# most recent one; empty if absent. Already on disk — no LLM call.
claude_code_title() {
	jq -r 'select(.type? == "summary") | .summary // empty' "$1" 2>/dev/null | tail -n1
}

# glob -> session-file glob pattern (used by doctor to detect the tool).
claude_code_glob() { printf '%s\n' "$HOME/.claude/projects/*/*.jsonl"; }

# hook_parse (optional) -> map this tool's UserPromptSubmit payload to three
# lines: prompt / transcript_path / cwd. Claude Code uses the standard field
# names, so the core's default parse already works and this is omitted.
