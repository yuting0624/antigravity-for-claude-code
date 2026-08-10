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
#             | 15 permission denied (agy >= 1.1.3 soft-denied a permissioned tool headless — pass --yolo)
#
# On a classifiable failure, a machine-readable line is printed to stderr so
# orchestrators (e.g. agy-job.sh) can react without scraping prose:
#   AGY_SIGNAL {"status":"QUOTA_EXHAUSTED","reason":"...","model":"...","retry":"--continue"}
#
# AGY_USAGE / AGY_SIGNAL go to stderr. If you are MEASURING cost, also set
# AGY_USAGE_LOG=/path/to/log: stderr is easily lost (`2>&1 | tail -N` keeps the
# digest and drops the usage line — see tee_usage below), a named file is not.
#
# agy is multi-model: tiers map to Gemini by default, but you can point delegation at any
# model `agy models` lists (e.g. Claude/GPT on plans that expose them). Defaults via plugin
# userConfig (env): CLAUDE_PLUGIN_OPTION_DEFAULT_TIER, _TIMEOUT, _DEFAULT_MODEL (exact name),
# _USAGE_LOG, and per-tier remaps _TIER_FLASH / _TIER_FLASH_LO / _TIER_PRO.
# Explicit --model/--tier win; AGY_USAGE_LOG wins over _USAGE_LOG.
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

# Optional side channel for AGY_USAGE / AGY_SIGNAL.
#
# WHY this exists: these lines go to stderr so they never pollute the conductor's
# context — but this skill also tells the conductor to keep its context lean, and
# the natural way to do that is `agy-delegate ... 2>&1 | tail -N`. stdout (the
# digest) is written after the usage line, so `tail` keeps the digest and throws
# the usage line away. Measured in the wild: a benchmark harness lost most of its
# Gemini-side cost data exactly this way, which made the hybrid look cheaper than
# it was. A file the caller names cannot be truncated by a pipe.
#
# Set AGY_USAGE_LOG=/path/to/log (or the plugin option `usage_log`). Appended to,
# never truncated; failure to write is non-fatal (measurement must not break work).
USAGE_LOG="${AGY_USAGE_LOG:-${CLAUDE_PLUGIN_OPTION_USAGE_LOG:-}}"
tee_usage() { # $1 = the full line, already formatted
  [ -n "$USAGE_LOG" ] || return 0
  # `2>/dev/null` FIRST: redirections apply left to right, so with `>>"$f" 2>/dev/null`
  # the append is attempted while stderr is still the real stderr — an unwritable path
  # then leaks a bash redirection error on every single call. Order matters here.
  printf '%s\n' "$1" 2>/dev/null >>"$USAGE_LOG" || true
}

# Emit a one-line machine-readable failure signal to stderr. $1=status $2=reason.
# QUOTA failures advertise `--continue` so a caller knows how to resume the session.
signal() {
  local status="$1" reason="$2" retry="" line
  [ "$status" = "QUOTA_EXHAUSTED" ] && retry="--continue"
  # sanitize reason so the JSON stays single-line and valid (no quotes/backslashes/newlines)
  reason="$(printf '%s' "$reason" | tr '\n\r\t' '   ' | tr -d '"\\' | cut -c1-200)"
  line="$(printf 'AGY_SIGNAL {"status":"%s","reason":"%s","model":"%s","retry":"%s"}' \
    "$status" "$reason" "${MODEL:-}" "$retry")"
  printf '%s\n' "$line" >&2
  tee_usage "$line"
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

# Heads-up: a likely write task with no visible write grant. Headless agy's write
# behavior has shifted across versions (describe-only pre-1.1.0; scratch-divert
# 1.1.0-1.1.2; soft-deny with a stderr notice on 1.1.3), and without a grant YOUR
# WORKSPACE IS UNTOUCHED while the run still "succeeds" (issue #10).
#
# There are TWO grants, and this used to claim there was one. A `write_file(<dir>)`
# rule under `permissions.allow` in ~/.gemini/antigravity-cli/settings.json grants
# headless writes beneath that path with no --yolo at all — confirmed on agy 1.1.9 by
# a controlled A/B (#37): covered target wrote, uncovered target came back
# PERMISSION_DENIED with the rule as the only variable. The match is a RECURSIVE
# PREFIX, not one directory. agy's own denial text names the rule and offers --yolo as
# the alternative, so the CLI has been saying this for a while and we were not.
#
# We cannot see settings.json from here (it is not ours, and --dir is not where it
# lives), so this stays a warning rather than a check — but it must not assert that
# --yolo is required. It fired immediately before a write that then succeeded.
# (--mode accept-edits worked headless only on 1.1.0-1.1.2 and is soft-denied on 1.1.3.)
# Best-effort heuristic; warn only. --print-command (dry run) is exempt.
if [ "$YOLO" -eq 0 ] && [ "$PRINT_CMD" -ne 1 ]; then
  shopt -s nocasematch
  case "$PROMPT" in
    *implement*|*scaffold*|*migrate*|*refactor*|*"write the file"*|*"create the file"*|*"edit the file"*)
      echo "agy-delegate: note: this looks like a write task and --yolo is not set. Headless agy will NOT touch your workspace without a write grant (it describes / scratch-diverts / soft-denies depending on version, while the run still 'succeeds'; issue #10). Two grants work: a permissions.allow rule matching the target — write_file(<dir>), a recursive prefix, in ~/.gemini/antigravity-cli/settings.json — which is the narrower one and needs no flag; or --yolo, which auto-approves ALL tools. If a rule already covers your target, ignore this — but <dir> is a placeholder, and agy-doctor will tell you whether yours actually parses. Otherwise add one, or pass --yolo on a dedicated branch, and verify with git status." >&2 ;;
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

# --- structured output (agy >= 1.1.8) -----------------------------------------
# agy gained `--output-format json`, which is strictly better for a wrapper than
# scraping prose: it carries status/error explicitly and a real `usage` object
# (input/output/thinking/cache_read tokens). We use it INTERNALLY and keep the
# stdout contract unchanged — callers still get the model's text on stdout — while
# classification gets the structured error and token usage goes to stderr as an
# AGY_USAGE line (stderr, so it never pollutes the conductor's context).
#
# Gated three ways, falling back to plain text if any is unmet:
#   * agy actually advertises --output-format (older versions don't),
#   * python3 is available to parse (the bash-only path stays dependency-free),
#   * the user hasn't opted out (structured_output=off).
# NOTE: agy 1.1.8 emits a RAW newline inside the "response" string, which strict
# JSON parsers reject — so we parse with strict=False. (Reported upstream.)
# Resolved BEFORE the capability probe below, not just before the main call: the
# probe was the one unbounded `agy` invocation left in this script. Measured, it
# returns in ~0.08s — but doctor's own hint documents a hang this release does NOT
# fix (agy blocking internally while an MCP server never finishes connecting), and
# an unguarded call is an unguarded call.
TO_CMD="$(timeout_cmd || true)"

# One trap for every temp file this script makes, installed before the first one
# exists. Declaring them empty up front means the probe's file is covered too —
# it used to be cleaned by a trailing `rm -f`, which a SIGINT during the probe
# skips. `rm -f ""` is a silent no-op, so the unset ones cost nothing.
HELPF=""; ERR=""; OUTF=""
trap 'rm -f "$HELPF" "$ERR" "$OUTF" 2>/dev/null' EXIT

JSON_MODE=0
raw_so="${CLAUDE_PLUGIN_OPTION_STRUCTURED_OUTPUT:-on}"
case "$(printf '%s' "$raw_so" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
  off|false|0|no|disabled) ;;
  *)
    if [ "$PRINT_CMD" -ne 1 ] && command -v python3 >/dev/null 2>&1; then
      # Capability probe. Deliberately NOT `agy --help | grep -q`: `grep -q` exits at
      # the first match and closes the pipe, so `agy --help` can die of SIGPIPE (141)
      # and, under `set -o pipefail`, the whole pipeline reads as "failed" — silently
      # disabling JSON mode. That race actually bit a benchmark run (~75% of calls on a
      # loaded container), and it is indistinguishable from "no delegation happened",
      # which is the worst kind of failure. Capture once, match with a shell glob.
      # Same pipe hazard as the main call (issue #37): route via a temp file so
      # inherited MCP children can never hold the capture pipe open.
      HELPF="$(mktemp "${TMPDIR:-/tmp}/agy-help.XXXXXX")"
      # 15s is ~180x the measured time; it fires only on a real hang, and losing
      # JSON mode is the right failure — the plain-text path still works.
      if [ -n "$TO_CMD" ]; then
        "$TO_CMD" --kill-after=5 15 agy --help >"$HELPF" 2>&1 || true
      else
        agy --help >"$HELPF" 2>&1 || true
      fi
      # `|| true` so the assignment cannot fail under `set -e` and skip the rm.
      agy_help="$(cat "$HELPF" 2>/dev/null || true)"; rm -f "$HELPF"
      case "$agy_help" in
        *--output-format*) JSON_MODE=1; ARGS+=(--output-format json) ;;
      esac
    fi ;;
esac

# --- dry run: print the resolved (shell-quoted) agy invocation and exit ---
if [ "$PRINT_CMD" -eq 1 ]; then
  { printf 'agy'; printf ' %q' "${ARGS[@]}" -p "$PROMPT"; printf '\n'; }
  exit 0
fi

# --- run (always detach stdin so non-TTY stdout is not dropped) ---
# Per-invocation temp file for stderr (mktemp avoids the race + symlink risk of a
# fixed /tmp path when multiple delegations run concurrently). Cleaned up on exit.
ERR="$(mktemp "${TMPDIR:-/tmp}/agy-delegate.XXXXXX")"
# stdout goes to a file too, never a command-substitution pipe: agy's stdio MCP
# children inherit our stdout and can outlive agy, so `$(agy ...)` blocks forever
# waiting for EOF even after `timeout` kills agy itself (issue #37). A regular
# file is inherited harmlessly.
OUTF="$(mktemp "${TMPDIR:-/tmp}/agy-out.XXXXXX")"

# Wall-clock guard: on a non-TTY caller (the whole point of this wrapper), agy can
# hard-hang before its own --print-timeout engages (notably native Windows without
# a ConPTY — see issue #6). Wrap in GNU `timeout`/`gtimeout` when available so we
# always return instead of hanging forever. `timeout` exits 124 on kill -> map to
# our TIMEOUT (12) and emit the structured signal, so orchestrators react cleanly.
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
  "$TO_CMD" --kill-after=10 "$TO_SECS" agy "${ARGS[@]}" -p "$PROMPT" < /dev/null >"$OUTF" 2>"$ERR"
  RC=$?
else
  agy "${ARGS[@]}" -p "$PROMPT" < /dev/null >"$OUTF" 2>"$ERR"
  RC=$?
fi
OUT="$(cat "$OUTF" 2>/dev/null)"
set -e

# --- unwrap the structured envelope (JSON mode) --------------------------------
# Replaces OUT with the model's text so the stdout contract is unchanged, exposes
# the structured error for classification, and reports token usage on stderr.
# Any parse failure falls back to treating OUT as plain text (never fatal).
JSON_STATUS=""; JSON_ERROR=""
if [ "$JSON_MODE" -eq 1 ] && [ -n "${OUT//[$' \t\n\r']/}" ]; then
  # The response can be multi-line, so it goes to a temp file; the single-line
  # metadata comes back on stdout. (Command substitution strips NUL bytes, so a
  # NUL-delimited stream is not an option here.)
  RESP="$(mktemp "${TMPDIR:-/tmp}/agy-resp.XXXXXX")"
  # The error text goes to its OWN file, not back out through `meta`. agy's error
  # strings quote the offending value (`--model \"foo\"`), and pulling the field out
  # of `meta` with sed truncates at that first escaped quote — which silently hid the
  # diagnostic from the classifier, so a bad --model/tier remap reported a generic
  # "agy failed" (exit 2) instead of MODEL_UNAVAILABLE (14). Let python, which already
  # has the parsed object, write the raw value out.
  JERR="$(mktemp "${TMPDIR:-/tmp}/agy-err.XXXXXX")"
  meta="$(AGY_JSON="$OUT" AGY_RESP_FILE="$RESP" AGY_ERR_FILE="$JERR" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
raw = os.environ.get("AGY_JSON", "")
try:
    # strict=False: agy 1.1.8 leaves raw newlines inside "response".
    d = json.loads(raw, strict=False)
    if not isinstance(d, dict): raise ValueError
except Exception:
    sys.exit(1)
with open(os.environ["AGY_RESP_FILE"], "w", encoding="utf-8") as fh:
    fh.write(str(d.get("response", "") or ""))
with open(os.environ["AGY_ERR_FILE"], "w", encoding="utf-8") as fh:
    fh.write(" ".join(str(d.get("error", "") or "").split()))
u = d.get("usage") or {}
def n(k):
    v = u.get(k)
    return v if isinstance(v, int) else 0
one_line = lambda s: " ".join(str(s or "").split())
print(json.dumps({
    "status": str(d.get("status", "")),
    "error": one_line(d.get("error", "")),
    "usage": {"input": n("input_tokens"), "output": n("output_tokens"),
              "thinking": n("thinking_tokens"), "cache_read": n("cache_read_tokens"),
              "total": n("total_tokens")},
    "conversation_id": str(d.get("conversation_id", "") or ""),
}))
PY
)"
  if [ -n "$meta" ]; then
    # `status` is a bare enum with no quotes inside it, so sed is safe there.
    JSON_STATUS="$(printf '%s' "$meta" | sed -n 's/.*"status": *"\([^"]*\)".*/\1/p')"
    JSON_ERROR="$(cat "$JERR" 2>/dev/null)"
    OUT="$(cat "$RESP" 2>/dev/null)"
    printf 'AGY_USAGE %s\n' "$meta" >&2
    tee_usage "AGY_USAGE $meta"
    # A structured ERROR is authoritative even if agy exited 0.
    [ "$JSON_STATUS" = "ERROR" ] && [ "$RC" -eq 0 ] && RC=1
  fi
  rm -f "$RESP" "$JERR"
fi

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
  # In JSON mode agy puts the diagnostic in the envelope instead of stderr — relay it
  # so the failure is still visible to a human reading the transcript.
  [ -n "$JSON_ERROR" ] && printf '%s\n' "$JSON_ERROR" >&2
  # Best-effort classification into a structured code (the generic 2 is the safe
  # fallback). Scans agy's diagnostics only — never the model-generated response,
  # which could contain trigger words and misclassify. In JSON mode (agy >= 1.1.8)
  # the diagnostic lives in the envelope's `error` field and stderr is typically
  # empty, so prefer that; otherwise fall back to stderr. Patterns are deliberately
  # specific to avoid false positives on incidental substrings.
  blob="$(cat "$ERR" 2>/dev/null)"
  [ -n "$JSON_ERROR" ] && blob="$JSON_ERROR
$blob"
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
  # agy >= 1.1.3 soft-denies a tool needing permission in headless mode and returns
  # rc=0 with EMPTY stdout plus an explanatory stderr notice (the evolved issue #10:
  # earlier versions silently wrote to a scratch dir or only described the edit). Detect
  # it so the caller gets an actionable signal instead of a bare "empty output".
  eblob="$(cat "$ERR" 2>/dev/null)"
  shopt -s nocasematch
  case "$eblob" in
    *"auto-denied"*|*"permissions.allow"*|*"permission that headless"*|*"dangerously-skip-permissions"*)
      shopt -u nocasematch
      [ -s "$ERR" ] && cat "$ERR" >&2
      echo "agy-delegate: agy soft-denied a tool that needs permission (headless can't prompt) — no work was done. For a FILE WRITE, the narrower fix is a permissions.allow rule covering the target in ~/.gemini/antigravity-cli/settings.json — write_file(<dir>) matches recursively beneath <dir> — which needs no flag; --yolo also works but auto-approves ALL tools. Other tools (web / Vertex AI Search / terminal) need --yolo unless a rule covers them. agy's own message above names the specific permission it wanted. If a rule is ALREADY in that file and you are still reading this, suspect the rule: run agy-doctor, because an entry agy cannot parse grants nothing. (A command(...) rule naming no command ALSO auto-approved everything before agy 1.1.11; a mistyped write_file() never did). (agy >= 1.1.3)" >&2
      signal PERMISSION_DENIED "agy soft-denied a permissioned tool in headless — add a permissions.allow rule or pass --yolo"; exit 15 ;;
  esac
  shopt -u nocasematch
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
