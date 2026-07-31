#!/usr/bin/env bash
#
# agy-trace.sh — read what an agy delegation actually DID (transcript.jsonl).
# Part of the "Antigravity for Claude Code" plugin.
#
# EVERY agy run leaves a readable step-by-step JSONL trajectory — not just the
# internal subagents spawned by invoke_subagent (which is all this tool claimed
# to cover before; verified on agy 1.1.8 that plain delegations leave one too):
#   ~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl
# Unlike the opaque conversation .db blobs, these are auditable. `agy-delegate`
# prints the conversationId in its AGY_USAGE line, so a delegation's cost and its
# trajectory can be joined 1:1 — which is what makes the skill's non-negotiable
# "never trust agy's self-reported GREEN" rule actually checkable.
#
# WHAT IS RECORDED: one typed step per action — RUN_COMMAND (with exit_code and
# the command's OUTPUT), CODE_ACTION, VIEW_FILE, LIST_DIRECTORY, PLANNER_RESPONSE.
# WHAT IS NOT: the command STRING itself. It appears in neither transcript.jsonl,
# transcript_full.jsonl, nor ~/.gemini/antigravity-cli/log/cli-*.log. You can see
# THAT a command ran, its exit code and its output — you cannot reconstruct it.
# To attribute a filesystem change, diff the tree; this tool cannot tell you.
#
# Usage:
#   agy-trace.sh <conversationId | path/to/transcript.jsonl>   Pretty-print the steps
#   agy-trace.sh --audit <conversationId | path | --last>      Step-type counts + failed commands
#   agy-trace.sh --last                                        Pretty-print the most recent run
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
  echo "agy-trace: hint: 'agy-trace --list' shows recent runs; the conversationId is in agy-delegate's AGY_USAGE line" >&2
  exit 2
}

# Newest transcript on disk. Used by --last and by '--audit --last'.
latest() {
  local f
  # shellcheck disable=SC2012
  f="$(ls -t "$BRAIN"/*/.system_generated/logs/transcript.jsonl 2>/dev/null | head -1)"
  [ -n "$f" ] || { echo "agy-trace: no transcripts under $BRAIN" >&2; exit 2; }
  printf '%s\n' "$f"
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
    echo "agy-trace: no transcripts under $BRAIN" >&2
    echo "agy-trace: (one is written per agy run — delegate something first)" >&2
    exit 2
  fi
}

# Audit summary: what the executor DID, in one screen. This is the verification
# surface for a delegation — step-type counts plus every command that failed.
audit() { # $1 = transcript path
  echo "# audit $1"
  python3 - "$1" <<'PY'
import json, sys, collections
counts, failures, steps = collections.Counter(), [], 0
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            counts["(unparseable)"] += 1
            continue
        steps += 1
        counts[str(d.get("type", "?"))] += 1
        # exit_code is absent on non-command steps; 0 is success, anything else is not.
        rc = d.get("exit_code")
        if isinstance(rc, int) and rc != 0:
            out = " ".join(str(d.get("content") or "").split())
            failures.append((d.get("step_index", "?"), rc, out[:200]))
print(f"  steps          {steps}")
for k, v in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
    print(f"  {k:<22} {v}")
if failures:
    print(f"  FAILED COMMANDS ({len(failures)}):")
    for idx, rc, out in failures:
        print(f"    [step {idx}] exit={rc}  {out}")
else:
    print("  no non-zero exit codes")
print("  NOTE: command strings are not recorded by agy — exit codes and output only.")
PY
}

pretty() { # $1 = transcript path
  echo "# $1"
  python3 - "$1" <<'PY'
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
  --last)    T="$(latest)" || exit $?
             pretty "$T" ;;
  --audit)   shift; [ $# -ge 1 ] || die "--audit needs a conversationId, a path, or --last"
             if [ "$1" = "--last" ]; then T="$(latest)" || exit $?
             else T="$(resolve "$1")" || exit $?; fi
             audit "$T" ;;
  --raw)     shift; [ $# -ge 1 ] || die "--raw needs a conversationId or path"
             # resolve in an assignment so its exit code (2 = not found) propagates
             # instead of being swallowed by a command-substitution subshell.
             T="$(resolve "$1")" || exit $?
             cat "$T" ;;
  -*)        die "unknown option '$1'" ;;
  *)         T="$(resolve "$1")" || exit $?
             pretty "$T" ;;
esac
