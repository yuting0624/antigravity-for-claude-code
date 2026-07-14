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
#       --digest                     Append a digest-only output contract to the prompt
#                                    (ingest digests, not raw dumps — the biggest cost lever)
#       --mode <accept-edits|plan>   agy execution mode (agy >= 1.1.0). accept-edits: auto-apply
#                                    FILE EDITS to the workspace without granting terminal/tool
#                                    permissions (the safer choice for pure write tasks — narrower
#                                    than --yolo). plan: strategize only, touch nothing.
#   -c, --continue                   Resume the most recent agy conversation (stateful)
#       --conversation <id>          Resume a specific agy conversation by ID (stateful)
#   -m, --model <exact name>         Use an exact agy model (any from `agy models`: Gemini/Claude/GPT…)
#       --print-command              Print the resolved agy command and exit (dry run)
#   -h, --help                       Show this help
#
# Exit codes: 0 ok | 1 usage | 2 agy failed | 3 empty | 10 quota | 11 auth | 12 timeout
#             | 13 agy missing | 14 model unavailable (--model / tier remap not in `agy models`)
#
# On a classifiable failure, a machine-readable line is printed to stderr so
# orchestrators (e.g. agy-job.sh) can react without scraping prose:
#   AGY_SIGNAL {"status":"QUOTA_EXHAUSTED","reason":"...","model":"...","retry":"--continue"}
#
# agy is multi-model: tiers map to Gemini by default, but you can point delegation at any
# model `agy models` lists (e.g. Claude/GPT on plans that expose them). Defaults via plugin
# userConfig (env): CLAUDE_PLUGIN_OPTION_DEFAULT_TIER, _TIMEOUT, _DEFAULT_MODEL (exact name),
# and per-tier remaps _TIER_FLASH / _TIER_FLASH_LO / _TIER_PRO. Explicit --model/--tier win.
#
set -euo pipefail

TIER="${CLAUDE_PLUGIN_OPTION_DEFAULT_TIER:-flash}"
TIMEOUT="${CLAUDE_PLUGIN_OPTION_TIMEOUT:-5m}"
TIER_EXPLICIT=0
MODEL=""
YOLO=0
SANDBOX=0
DIGEST=0
MODE=""
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
# Defaults are Gemini, but each tier is remappable to any agy model via userConfig
# (env), so non-Vertex/non-Gemini plans (Claude/GPT) work without code changes.
model_for_tier() {
  case "$1" in
    flash)    echo "${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-Gemini 3.5 Flash (High)}" ;;
    flash-lo) echo "${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-Gemini 3.5 Flash (Low)}" ;;
    pro)      echo "${CLAUDE_PLUGIN_OPTION_TIER_PRO:-Gemini 3.1 Pro (High)}" ;;
    *) die "unknown tier '$1' (use flash | flash-lo | pro)" ;;
  esac
}

# True when running under WSL (Windows Subsystem for Linux).
on_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }

# True on native Windows (Git Bash / MSYS / Cygwin) — NOT WSL. On native Windows
# without a real console (ConPTY), agy v1.0.x can hard-hang with a 0-byte log when
# its stdio is redirected (the issue this wall-clock guard defends against).
on_windows_native() {
  case "${OSTYPE:-}" in msys*|cygwin*|win32) return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

# Resolve a usable `timeout`-style command: GNU coreutils `timeout`, or macOS
# Homebrew's `gtimeout`. Echoes the command name, or empty if neither exists.
# We wrap agy in this so a headless/no-TTY hang (agy never returns) is bounded by
# wall-clock — agy's own --print-timeout can't fire if it hangs before starting.
timeout_cmd() {
  if command -v timeout  >/dev/null 2>&1; then echo timeout;  return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then echo gtimeout; return 0; fi
  return 1
}

# Convert an agy-style duration (e.g. 5m, 300s, 1h, or a bare number=seconds) to
# whole seconds, then add a small head-room margin so the OUTER wall-clock guard
# fires only AFTER agy's own --print-timeout has had its chance. Echoes seconds.
outer_timeout_secs() {
  local d="${1:-5m}" n unit secs
  n="${d%[smh]}"; unit="${d#"$n"}"
  case "$n" in (*[!0-9]*|'') n=300; unit=s ;; esac
  case "$unit" in
    h) secs=$(( n * 3600 )) ;;
    m) secs=$(( n * 60 )) ;;
    s|'') secs=$(( n )) ;;
    *) secs=$(( n )) ;;
  esac
  # head-room so the OUTER guard never pre-empts agy's own --print-timeout on a
  # legitimately-slow-but-progressing call: +25% of the budget, min 10s, capped 120s.
  local pad=$(( secs / 4 ))
  [ "$pad" -lt 10 ]  && pad=10
  [ "$pad" -gt 120 ] && pad=120
  echo $(( secs + pad ))
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tier)      need "$#" "$1"; TIER="$2"; TIER_EXPLICIT=1; shift 2 ;;
    -d|--dir)       need "$#" "$1"; ADD_DIRS+=("$2"); shift 2 ;;
    --timeout)      need "$#" "$1"; TIMEOUT="$2"; shift 2 ;;
    --yolo)         YOLO=1; shift ;;
    --sandbox)      SANDBOX=1; shift ;;
    --digest)       DIGEST=1; shift ;;               # ask agy for a digest-only reply
    --mode)         need "$#" "$1"; MODE="$2"; shift 2
                    case "$MODE" in accept-edits|plan) ;;
                      *) die "invalid --mode '$MODE' (use accept-edits | plan; agy >= 1.1.0)" ;;
                    esac ;;
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

# Resolve the executor model. Precedence:
#   --model > explicit --tier > userConfig default_model > default tier (mapped).
# agy is multi-model; tiers default to Gemini but are remappable (see model_for_tier).
if [ -z "$MODEL" ]; then
  if [ "$TIER_EXPLICIT" -eq 1 ]; then
    MODEL="$(model_for_tier "$TIER")"
  elif [ -n "${CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL:-}" ]; then
    MODEL="$CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL"
  else
    # default tier from userConfig; a bad value shouldn't make every call die.
    case "$TIER" in
      flash|flash-lo|pro) ;;
      *) echo "agy-delegate: invalid default tier '$TIER' (set CLAUDE_PLUGIN_OPTION_DEFAULT_TIER to flash|flash-lo|pro); using flash" >&2; TIER="flash" ;;
    esac
    MODEL="$(model_for_tier "$TIER")"
  fi
fi

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

# Heads-up: a likely write task without write permission. Headless agy without
# --mode accept-edits / --yolo either only DESCRIBES edits (pre-1.1.0) or writes them
# to its OWN scratch dir (~/.gemini/antigravity-cli/scratch, 1.1.0 review-first default)
# — either way YOUR WORKSPACE IS UNTOUCHED while agy reports success (issue #10).
# Best-effort heuristic; warn only. --print-command (dry run) is exempt.
if [ "$YOLO" -eq 0 ] && [ "$MODE" != "accept-edits" ] && [ "$PRINT_CMD" -ne 1 ]; then
  shopt -s nocasematch
  case "$PROMPT" in
    *implement*|*scaffold*|*migrate*|*refactor*|*"write the file"*|*"create the file"*|*"edit the file"*)
      echo "agy-delegate: note: this looks like a write task but neither --mode accept-edits nor --yolo is set — headless agy will describe the edits or write them to its own scratch dir, NOT your workspace, while still reporting success (issue #10). Use --mode accept-edits for pure file writes (agy >= 1.1.0), or --yolo when the task also needs tools (web/terminal); run write tasks on a branch." >&2 ;;
  esac
  shopt -u nocasematch
fi

# --digest: append an explicit output contract so agy returns a compact digest
# instead of raw content. Ingesting digests (never dumps) is the plugin's single
# biggest cost lever — it keeps the conductor's context lean (issue #5).
# (Appended AFTER the write-task heuristic so that scans the user's prompt only.)
if [ "$DIGEST" -eq 1 ]; then
  PROMPT="$PROMPT

OUTPUT CONTRACT (digest): reply with ONLY a compact digest — short bullets (findings / decisions / errors, with file:line references where useful). NO full file contents, NO raw logs, NO long code blocks. End with exactly one line: DIGEST: <one-sentence summary>."
fi

# --- assemble agy args ---
# NOTE: in agy, -p/--print/--prompt TAKES THE PROMPT AS ITS VALUE, so it must come
# last with the prompt attached. Other flags go before it.
ARGS=(--model "$MODEL" --print-timeout "$TIMEOUT")
for d in "${ADD_DIRS[@]:-}"; do [ -n "$d" ] && ARGS+=(--add-dir "$d"); done
[ "$YOLO" -eq 1 ]      && ARGS+=(--dangerously-skip-permissions)
[ -n "$MODE" ]         && ARGS+=(--mode "$MODE")     # agy >= 1.1.0
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

# Wall-clock guard: on a non-TTY caller (the whole point of this wrapper), agy can
# hard-hang before its own --print-timeout engages (notably native Windows without
# a ConPTY — see issue #6). Wrap in GNU `timeout`/`gtimeout` when available so we
# always return instead of hanging forever. `timeout` exits 124 on kill -> map to
# our TIMEOUT (12) and emit the structured signal, so orchestrators react cleanly.
TO_CMD="$(timeout_cmd || true)"
TO_SECS="$(outer_timeout_secs "$TIMEOUT")"

if on_windows_native && [ -z "$TO_CMD" ]; then
  # Native Windows + no timeout binary = highest hang risk with no safety net.
  echo "agy-delegate: WARNING — native Windows without GNU \`timeout\`/\`gtimeout\` on PATH." >&2
  echo "agy-delegate:   headless \`agy -p\` can hang here with a 0-byte log (no ConPTY). If this" >&2
  echo "agy-delegate:   call never returns, run from WSL/macOS/Linux, or install coreutils \`timeout\`." >&2
fi

set +e
if [ -n "$TO_CMD" ]; then
  # --kill-after sends SIGKILL if agy ignores the initial SIGTERM (defensive).
  OUT="$("$TO_CMD" --kill-after=10 "$TO_SECS" agy "${ARGS[@]}" -p "$PROMPT" < /dev/null 2>"$ERR")"
  RC=$?
else
  OUT="$(agy "${ARGS[@]}" -p "$PROMPT" < /dev/null 2>"$ERR")"
  RC=$?
fi
set -e

# `timeout` exits 124 (SIGTERM) or 137 (SIGKILL after --kill-after) when it had to
# kill agy. Treat that as our structured TIMEOUT (exit 12), not a generic failure.
if [ -n "$TO_CMD" ] && { [ $RC -eq 124 ] || [ $RC -eq 137 ]; }; then
  echo "agy-delegate: agy hit the wall-clock guard (${TO_SECS}s) and was terminated — likely a headless/no-TTY hang." >&2
  if on_windows_native; then
    echo "agy-delegate:   native Windows: agy needs a console (ConPTY); run delegation from WSL/macOS/Linux." >&2
  fi
  signal TIMEOUT "agy wall-clock guard fired after ${TO_SECS}s (headless/no-TTY hang?)"
  exit 12
fi

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
    *"invalid --model"*|*"is not recognized as a known model"*|*"not a known model"*)
      # agy >= 1.1.2 hard-fails (instead of silently downgrading) when --model can't be
      # resolved — common when a tier_* / default_model remap points at a model this plan
      # doesn't expose. Surface it as its own actionable category.
      shopt -u nocasematch
      echo "agy-delegate: model '$MODEL' is not available on this plan — run \`agy models\`, then fix --model / the tier_* / default_model option." >&2
      signal MODEL_UNAVAILABLE "model not in \`agy models\` (check --model / tier remaps)"; exit 14 ;;
  esac
  shopt -u nocasematch
  signal AGY_FAILED "agy exited $RC"
  exit 2
fi
if [ -z "${OUT//[$' \t\n\r']/}" ]; then
  echo "agy-delegate: agy returned empty output (model='$MODEL')" >&2
  exit 3
fi

# Digest-size guard: the cost saving depends on the conductor ingesting a DIGEST,
# not a raw dump — if the reply is dump-sized, say so on stderr (advisory only;
# stdout passes through untouched). Tune via the digest_warn_chars plugin option
# (env CLAUDE_PLUGIN_OPTION_DIGEST_WARN_CHARS; empty = 8000, 0 = off).
WARN_CHARS="${CLAUDE_PLUGIN_OPTION_DIGEST_WARN_CHARS:-8000}"
case "$WARN_CHARS" in (*[!0-9]*|'') WARN_CHARS=8000 ;; esac
if [ "$WARN_CHARS" -gt 0 ] && [ "${#OUT}" -gt "$WARN_CHARS" ]; then
  echo "agy-delegate: note: output is ${#OUT} chars (> ${WARN_CHARS}) — that looks like a raw dump, not a digest. Don't ingest this into the conductor's context: re-run with --digest, or have agy summarize it first. (plugin option digest_warn_chars tunes this; 0 disables.)" >&2
fi

printf '%s\n' "$OUT"
