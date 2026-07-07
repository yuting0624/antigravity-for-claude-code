#!/usr/bin/env bash
#
# agy-trace.sh — read an agy SUBAGENT trajectory (transcript.jsonl).
# Part of the "Antigravity for Claude Code" plugin.
#
# When agy spawns internal subagents (invoke_subagent with TypeName "self" + a
# Role — see the skill's "Internal fan-out" recipe), each spawn's tool result
# includes a logAbsoluteUri pointing at a READABLE step-by-step JSONL transcript:
#   ~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl
# Unlike the opaque conversation .db blobs, these are auditable — this tool
# pretty-prints them so Claude can run a trajectory check on what a subagent
# actually did (verified on agy 1.0.12).
#
# Usage:
#   agy-trace.sh <conversationId | path/to/transcript.jsonl>   Pretty-print the steps
#   agy-trace.sh --raw <conversationId | path>                 Raw JSONL (pipe to jq etc.)
#   agy-trace.sh --list [N]                                    N most recent transcripts (default 10)
#   agy-trace.sh -h | --help
#
# Exit codes: 0 ok | 1 usage | 2 transcript not found
#
set -euo pipefail

# Override for tests; real location is agy's brain dir.
BRAIN="${AGY_BRAIN_DIR:-$HOME/.gemini/antigravity-cli/brain}"

die()   { echo "agy-trace: $*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Resolve an argument (conversationId or literal path) to a transcript file.
resolve() {
  local a="$1"
  if [ -f "$a" ]; then printf '%s\n' "$a"; return 0; fi
  local t="$BRAIN/$a/.system_generated/logs/transcript.jsonl"
  if [ -f "$t" ]; then printf '%s\n' "$t"; return 0; fi
  echo "agy-trace: no transcript for '$a' (looked for a file, then $t)" >&2
  echo "agy-trace: hint: 'agy-trace --list' shows recent subagent transcripts" >&2
  exit 2
}

list_recent() {
  local n="${1:-10}"
  case "$n" in (*[!0-9]*|'') n=10 ;; esac
  local found=0 f id when steps
  # newest first; glob may match nothing -> nullglob-like guard via -f check
  # shellcheck disable=SC2012
  for f in $(ls -t "$BRAIN"/*/.system_generated/logs/transcript.jsonl 2>/dev/null | head -"$n"); do
    [ -f "$f" ] || continue
    found=1
    id="${f#"$BRAIN"/}"; id="${id%%/*}"
    steps="$(wc -l < "$f" | tr -d ' ')"
    when="$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    printf '%s  %s  %s steps\n' "$when" "$id" "$steps"
  done
  if [ "$found" -eq 0 ]; then
    echo "agy-trace: no subagent transcripts under $BRAIN" >&2
    echo "agy-trace: (they appear after agy spawns internal subagents — see the skill's Internal fan-out recipe)" >&2
    exit 2
  fi
}

pretty() { # $1 = transcript path
  echo "# $1"
  local py="python3"
  if ! command -v python3 >/dev/null 2>&1 && command -v python >/dev/null 2>&1; then
    py="python"
  fi
  "$py" - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as fh:
    for i, line in enumerate(fh):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            print(f"[{i}] (unparseable line)")
            continue
        content = str(d.get("content") or "").replace("\n", " ")
        if len(content) > 160:
            content = content[:160] + "…"
        print(f"[{d.get('step_index', i)}] {str(d.get('type','?')):<28} {str(d.get('status','?')):<6} {content}")
PY
}

[ $# -ge 1 ] || die "no argument (pass a conversationId, a transcript path, or --list; -h for help)"
case "$1" in
  -h|--help) usage ;;
  --list)    shift; list_recent "${1:-10}" ;;
  --raw)     shift; [ $# -ge 1 ] || die "--raw needs a conversationId or path"
             # resolve in an assignment so its exit code (2 = not found) propagates
             # instead of being swallowed by a command-substitution subshell.
             T="$(resolve "$1")" || exit $?
             cat "$T" ;;
  -*)        die "unknown option '$1'" ;;
  *)         T="$(resolve "$1")" || exit $?
             pretty "$T" ;;
esac
