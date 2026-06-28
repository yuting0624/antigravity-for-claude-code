#!/usr/bin/env bash
#
# PreToolUse(Bash) gate for the `antigravity-delegate` subagent. Claude Code's
# subagent `tools:` field can't scope Bash to one command, so this hook enforces it:
# allow a Bash call ONLY when it invokes the plugin's delegation wrapper
# (agy-delegate / agy-job); block everything else with exit code 2.
#
# This keeps file writing + verification off the delegate subagent (file generation
# happens on agy/Gemini, not by spending Claude tokens in the shell).
#
# Input: hook JSON on stdin, with .tool_input.command holding the bash command.
#
set -uo pipefail

input="$(cat)"

# Extract the command field. Prefer python3 (correct JSON parse); fall back to the
# raw payload so the gate still works if python3 is unavailable.
if command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | python3 -c \
    'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception:
    pass' 2>/dev/null || true)"
else
  cmd="$input"
fi

case "$cmd" in
  *agy-delegate*|*agy-job*) exit 0 ;;
esac

echo "[antigravity-delegate] blocked: this subagent may only run agy-delegate / agy-job via Bash. Delegate file work to agy; verification is the caller's job." >&2
exit 2
