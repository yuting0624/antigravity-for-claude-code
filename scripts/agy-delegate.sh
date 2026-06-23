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
#       --print-command              Print the resolved agy command and exit (dry run)
#   -h, --help                       Show this help
#
# Exit codes: 0 ok | 1 usage | 2 agy failed | 3 empty | 10 quota | 11 auth | 12 timeout | 13 agy missing
#
# On a classifiable failure, a machine-readable line is printed to stderr so
# orchestrators (e.g. agy-job.sh) can react without scraping prose:
#   AGY_SIGNAL {"status":"QUOTA_EXHAUSTED","reason":"...","model":"...","retry":"--continue"}
#
# Defaults can be set via plugin userConfig (env): CLAUDE_PLUGIN_OPTION_DEFAULT_TIER,
# CLAUDE_PLUGIN_OPTION_TIMEOUT. Explicit --tier/--timeout always override.
#
set -euo pipefail

TIER="${CLAUDE_PLUGIN_OPTION_DEFAULT_TIER:-flash}"
TIMEOUT="${CLAUDE_PLUGIN_OPTION_TIMEOUT:-5m}"
TIER_EXPLICIT=0
MODEL=""
YOLO=0
SANDBOX=0
ADD_DIRS=()
PROMPT=""
CONTINUE=0
CONV_ID=""
PRINT_CMD=0

die() { echo "agy-delegate: $*" >&2; exit 1; }
# $1 = remaining argc ($#). Fail with a friendly message if an option has no value
# (avoids `shift 2` aborting under `set -e` with a cryptic "shift count" error).
need() { [ "$1" -ge 2 ] || die "option '$2' needs a value"; }

# Emit a one-line machine-readable failure signal to stderr. $1=status $2=reason.
# QUOTA failures advertise `--continue` so a caller knows how to resume the session.
signal() {
  local status="$1" reason="$2" retry=""
  [ "$status" = "QUOTA_EXHAUSTED" ] && retry="--continue"
  # sanitize reason so the JSON stays single-line and valid (no quotes/backslashes/newlines)
  reason="$(printf '%s' "$reason" | tr '\n\r\t' '   ' | tr -d '"\\' | cut -c1-200)"
  printf 'AGY_SIGNAL {"status":"%s","reason":"%s","model":"%s","retry":"%s"}\n' \
    "$status" "$reason" "${MODEL:-}" "$retry" >&2
}

# Print the header comment between "# Usage:" and "# Exit codes:" (anchored to
# content, not line numbers, so it never desyncs when the header changes).
usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- map a tier to an exact agy model name (see `agy models`) ---
model_for_tier() {
  case "$1" in
    flash)    echo "Gemini 3.5 Flash (High)" ;;
    flash-lo) echo "Gemini 3.5 Flash (Low)" ;;
    pro)      echo "Gemini 3.1 Pro (High)" ;;
    *) die "unknown tier '$1' (use flash | flash-lo | pro)" ;;
  esac
}

# True when running under WSL (Windows Subsystem for Linux).
on_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tier)      need "$#" "$1"; TIER="$2"; TIER_EXPLICIT=1; shift 2 ;;
    -d|--dir)       need "$#" "$1"; ADD_DIRS+=("$2"); shift 2 ;;
    --timeout)      need "$#" "$1"; TIMEOUT="$2"; shift 2 ;;
    --yolo)         YOLO=1; shift ;;
    --sandbox)      SANDBOX=1; shift ;;
    -c|--continue)  CONTINUE=1; shift ;;            # resume most recent agy conversation
    --conversation) need "$#" "$1"; CONV_ID="$2"; shift 2 ;; # resume a specific conversation by ID
    -m|--model)     need "$#" "$1"; MODEL="$2"; shift 2 ;;
    --print-command) PRINT_CMD=1; shift ;;          # dry run: show the resolved agy command
    -h|--help)      usage ;;
    -)              PROMPT="$(cat)"; shift ;;       # read prompt from stdin
    --)             shift; PROMPT="${*:-}"; break ;;
    -*)             die "unknown option '$1'" ;;
    *)              PROMPT="$*"; break ;;            # rest is the prompt
  esac
done

[ -n "$PROMPT" ] || die "no prompt given (pass a string, or '-' to read stdin)"
# --print-command is a dry run (introspection), so it doesn't require agy on PATH.
if [ "$PRINT_CMD" -ne 1 ] && ! command -v agy >/dev/null 2>&1; then
  echo "agy-delegate: 'agy' not found on PATH — install the Antigravity CLI first" >&2
  signal AGY_MISSING "agy not on PATH"
  exit 13
fi

# A bad default tier from userConfig (env) shouldn't make every call die — fall back to
# flash with a warning. An explicit --tier typo still errors (treated as user intent).
if [ "$TIER_EXPLICIT" -eq 0 ]; then
  case "$TIER" in
    flash|flash-lo|pro) ;;
    *) echo "agy-delegate: invalid default tier '$TIER' (set CLAUDE_PLUGIN_OPTION_DEFAULT_TIER to flash|flash-lo|pro); using flash" >&2; TIER="flash" ;;
  esac
fi

[ -n "$MODEL" ] || MODEL="$(model_for_tier "$TIER")"

# WSL gotcha: agy reads --add-dir over the /mnt/* Windows mount via a slow 9p bridge,
# so even trivial calls can take 20s+. Warn (don't fail); the fix is to move the repo
# into the WSL Linux filesystem (~).
if on_wsl; then
  for d in "${ADD_DIRS[@]:-}"; do
    [ -n "$d" ] || continue
    case "$d" in
      /mnt/*) echo "agy-delegate: note: --add-dir '$d' is on a Windows mount under WSL; agy reads it over a slow 9p bridge (calls can take 20s+). Move the repo into the Linux FS (~) for ~10x faster I/O." >&2; break ;;
    esac
  done
fi

# --- assemble agy args ---
# NOTE: in agy, -p/--print/--prompt TAKES THE PROMPT AS ITS VALUE, so it must come
# last with the prompt attached. Other flags go before it.
ARGS=(--model "$MODEL" --print-timeout "$TIMEOUT")
for d in "${ADD_DIRS[@]:-}"; do [ -n "$d" ] && ARGS+=(--add-dir "$d"); done
[ "$YOLO" -eq 1 ]      && ARGS+=(--dangerously-skip-permissions)
[ "$SANDBOX" -eq 1 ]   && ARGS+=(--sandbox)
[ "$CONTINUE" -eq 1 ]  && ARGS+=(--continue)        # keep working context on the cheap (Gemini) side
[ -n "$CONV_ID" ]      && ARGS+=(--conversation "$CONV_ID")

# --- dry run: print the resolved (shell-quoted) agy invocation and exit ---
if [ "$PRINT_CMD" -eq 1 ]; then
  { printf 'agy'; printf ' %q' "${ARGS[@]}" -p "$PROMPT"; printf '\n'; }
  exit 0
fi

# --- run (always detach stdin so non-TTY stdout is not dropped) ---
# Per-invocation temp file for stderr (mktemp avoids the race + symlink risk of a
# fixed /tmp path when multiple delegations run concurrently). Cleaned up on exit.
ERR="$(mktemp "${TMPDIR:-/tmp}/agy-delegate.XXXXXX")"
trap 'rm -f "$ERR"' EXIT
set +e
OUT="$(agy "${ARGS[@]}" -p "$PROMPT" < /dev/null 2>"$ERR")"
RC=$?
set -e

if [ $RC -ne 0 ]; then
  echo "agy-delegate: agy exited $RC" >&2
  [ -s "$ERR" ] && cat "$ERR" >&2
  # Best-effort classification into a structured code (the generic 2 is the safe
  # fallback). Scans agy's STDERR only — its diagnostics go there; model-generated
  # stdout could contain trigger words and misclassify. Patterns are deliberately
  # specific to avoid false positives on incidental substrings.
  blob="$(cat "$ERR" 2>/dev/null)"
  shopt -s nocasematch
  case "$blob" in
    *quota*|*"rate limit"*|*"resource exhausted"*)
      shopt -u nocasematch; signal QUOTA_EXHAUSTED "agy quota / rate limit"; exit 10 ;;
    *unauthenticated*|*unauthorized*|*"sign in"*|*"please authenticate"*|*reauth*)
      shopt -u nocasematch; signal AUTH_REQUIRED "agy not authenticated — run \`agy\` once"; exit 11 ;;
    *"timed out"*|*"deadline exceeded"*|*"print-timeout"*)
      shopt -u nocasematch; signal TIMEOUT "agy print-timeout / deadline exceeded"; exit 12 ;;
  esac
  shopt -u nocasematch
  signal AGY_FAILED "agy exited $RC"
  exit 2
fi
if [ -z "${OUT//[$' \t\n\r']/}" ]; then
  echo "agy-delegate: agy returned empty output (model='$MODEL')" >&2
  exit 3
fi

printf '%s\n' "$OUT"
