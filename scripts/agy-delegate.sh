#!/usr/bin/env bash
#
# agy-delegate.sh — robust headless wrapper around the Antigravity CLI (`agy`).
# Part of the "Antigravity for Claude Code" plugin.
#
# Purpose: let Claude Code (the orchestrator) hand a single, well-scoped subtask
# to an Antigravity (Gemini) agent via `agy --print`, and get clean text back on
# stdout — for delegation, cross-model checks, or offloading bulk work.
#
# Why a wrapper instead of calling `agy` directly:
#   * `agy --print` silently drops stdout when stdin is a non-TTY -> we always
#     redirect `< /dev/null` so it never blocks waiting for input.
#   * agy v1.0.x has NO `--output-format json`, so callers must parse plain text.
#     This wrapper guarantees: non-empty stdout on success, non-zero exit on
#     failure or empty output.
#   * Human-friendly tier names (flash / pro) instead of exact model strings.
#
# Usage:
#   agy-delegate.sh [options] "the task prompt"
#   echo "long prompt" | agy-delegate.sh [options] -      # read prompt from stdin
#
# Options:
#   -t, --tier <flash|flash-lo|pro>  Model tier (default: flash)
#   -d, --dir  <path>                Add a workspace dir (repeatable)
#       --timeout <dur>              Print-mode timeout, e.g. 10m (default: 5m)
#       --yolo                       Auto-approve all tool permissions (DANGEROUS)
#       --sandbox                    Run agent with terminal sandbox restrictions
#   -c, --continue                   Resume the most recent agy conversation (stateful)
#       --conversation <id>          Resume a specific agy conversation by ID (stateful)
#   -m, --model <exact name>         Override tier with an exact agy model name
#   -h, --help                       Show this help
#
# Exit codes: 0 ok | 1 usage error | 2 agy failed | 3 empty output
#
set -euo pipefail

TIER="flash"
TIMEOUT="5m"
MODEL=""
YOLO=0
SANDBOX=0
ADD_DIRS=()
PROMPT=""
CONTINUE=0
CONV_ID=""

die() { echo "agy-delegate: $*" >&2; exit 1; }

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- map a tier to an exact agy model name (see `agy models`) ---
model_for_tier() {
  case "$1" in
    flash)    echo "Gemini 3.5 Flash (High)" ;;
    flash-lo) echo "Gemini 3.5 Flash (Low)" ;;
    pro)      echo "Gemini 3.1 Pro (High)" ;;
    *) die "unknown tier '$1' (use flash | flash-lo | pro)" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tier)    TIER="${2:-}"; shift 2 ;;
    -d|--dir)     ADD_DIRS+=("${2:-}"); shift 2 ;;
    --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
    --yolo)       YOLO=1; shift ;;
    --sandbox)    SANDBOX=1; shift ;;
    -c|--continue) CONTINUE=1; shift ;;          # resume most recent agy conversation
    --conversation) CONV_ID="${2:-}"; shift 2 ;; # resume a specific conversation by ID
    -m|--model)   MODEL="${2:-}"; shift 2 ;;
    -h|--help)    usage ;;
    -)            PROMPT="$(cat)"; shift ;;       # read prompt from stdin
    --)           shift; PROMPT="${*:-}"; break ;;
    -*)           die "unknown option '$1'" ;;
    *)            PROMPT="$*"; break ;;            # rest is the prompt
  esac
done

[ -n "$PROMPT" ] || die "no prompt given (pass a string, or '-' to read stdin)"
command -v agy >/dev/null 2>&1 || die "'agy' not found on PATH — install the Antigravity CLI first"

[ -n "$MODEL" ] || MODEL="$(model_for_tier "$TIER")"

# --- assemble agy args ---
# NOTE: in agy, -p/--print/--prompt TAKES THE PROMPT AS ITS VALUE, so it must come
# last with the prompt attached. Other flags go before it.
ARGS=(--model "$MODEL" --print-timeout "$TIMEOUT")
for d in "${ADD_DIRS[@]:-}"; do [ -n "$d" ] && ARGS+=(--add-dir "$d"); done
[ "$YOLO" -eq 1 ]      && ARGS+=(--dangerously-skip-permissions)
[ "$SANDBOX" -eq 1 ]   && ARGS+=(--sandbox)
[ "$CONTINUE" -eq 1 ]  && ARGS+=(--continue)        # keep working context on the cheap (Gemini) side
[ -n "$CONV_ID" ]      && ARGS+=(--conversation "$CONV_ID")

# --- run (always detach stdin so non-TTY stdout is not dropped) ---
set +e
OUT="$(agy "${ARGS[@]}" -p "$PROMPT" < /dev/null 2>/tmp/agy-delegate.err)"
RC=$?
set -e

if [ $RC -ne 0 ]; then
  echo "agy-delegate: agy exited $RC" >&2
  [ -s /tmp/agy-delegate.err ] && cat /tmp/agy-delegate.err >&2
  exit 2
fi
if [ -z "${OUT//[$' \t\n\r']/}" ]; then
  echo "agy-delegate: agy returned empty output (model='$MODEL')" >&2
  exit 3
fi

printf '%s\n' "$OUT"
