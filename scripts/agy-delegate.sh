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
#   * `agy --print` silently drops stdout when stdin is a non-TTY -> we detach
#     stdin (`< /dev/null`) for short prompts and pipe via a rewindable temp file
#     (`< "$PROMPTF"` without `-p`) above 64 KB to avoid Linux E2BIG.
#   * Structured JSON unwrapping (`--output-format json` on agy >= 1.1.8) with
#     plain-text fallback, non-empty stdout guarantee, and structured AGY_USAGE /
#     AGY_SIGNAL telemetry on stderr.
#   * Human-friendly Gemini 4 tier names (`flash` = Hydrogen High, `flash-lo` =
#     Hydrogen Low, `pro` = Carbon High) with 1-hop `Available models:` pruning
#     and a 6-hour fingerprinted warm fallback cache on plans without Carbon/Hydrogen.
#
# Usage:
#   agy-delegate.sh [options] "the task prompt"
#   echo "long prompt" | agy-delegate.sh [options] -      # read prompt from stdin
#
# Options:
#   -t, --tier <flash|flash-lo|pro>  Model tier (default: flash = Gemini 4 Hydrogen High;
#                                    flash-lo/lite = Hydrogen Low; pro = Gemini 4 Carbon High;
#                                    power aliases: argon, flash-38)
#   -e, --effort <low|medium|high|xhigh|max>
#                                    Reasoning effort override (rewrites tier display-name suffix,
#                                    or passes --effort to agy for base slugs / gateway models)
#   -d, --dir, --add-dir <path>      Add a workspace dir (repeatable)
#       --timeout <dur>              Print-mode timeout, e.g. 10m, or 0 for unbounded (default: 5m)
#       --read-only                  Enforce read-only session settings on agy >= 1.4.10
#                                    (agentMode="", toolPermission="request-review", allow=[]);
#                                    neutralizes agy 1.5.7+ default Auto mode
#       --allow-url                  With --read-only (or standalone), permit URL fetches
#                                    (read_url(*)) while keeping writes and shell commands blocked
#       --settings <json>            Pass ephemeral per-session settings JSON (agy >= 1.4.10)
#       --json-schema <schema>       Enforce a JSON object schema on the final output (agy >= 1.4.x)
#       --yolo                       Auto-approve all tool permissions (DANGEROUS). Reaches agy as
#                                    --dangerously-skip-permissions; agy 1.1.25 rejects a literal --yolo
#       --sandbox                    Run agent with terminal sandbox restrictions (NOT containment)
#       --digest                     Append a digest-only output contract to the prompt
#                                    (ingest digests, not raw dumps — the biggest cost lever)
#       --mode <accept-edits|plan|auto> agy execution mode (agy >= 1.1.0; auto >= 1.3.5). On agy 1.5.7+,
#                                    accept-edits auto-approves write_file inside --dir/--add-dir
#                                    (never shell commands or outside paths); on agy 1.1.13–1.5.6 it
#                                    was not a headless write grant and denied like a plain write.
#                                    plan: strategize only. auto: dynamic plan/execute.
#   -c, --continue                   Resume the most recent agy conversation (stateful)
#       --conversation <id>          Resume a specific agy conversation by ID (stateful)
#   -m, --model <exact name>         Use an exact agy model (any from `agy models`: Gemini/Claude/GPT…)
#       --allow-slash-commands       Keep agy's leading `/command` expansion enabled in print mode
#                                    (by default --disable-slash-commands is passed when MODE != plan
#                                    so literal `/clear` or `/credits` text in prompts never aborts)
#       --print-command              Print the resolved agy command and exit (dry run)
#   -h, --help                       Show this help
#
# Exit codes: 0 ok | 1 usage | 2 agy failed | 3 empty | 10 quota | 11 auth | 12 timeout
#             |    (agy's own, the wall-clock guard, or — agy 1.1.28+ — a --print-timeout that
#             |    expired mid-turn or while waiting on background tasks: agy 1.1.28–1.4.x returns
#             |    the PARTIAL reply with rc 0, and agy 1.5.0+ exits 3 with finished_reason /
#             |    AGY_ERROR reason "print_timeout"; the wrapper prints that partial reply and
#             |    still exits 12). Not when JSON mode has a complete SUCCESS reply and agy just
#             |    failed to exit after it (agy 1.4.4): that prints the reply, warns on stderr and
#             |    exits 0
#             | 13 agy missing | 14 model unavailable (--model / tier remap not in `agy models`)
#             | 15 permission denied — a tool needed permission headless. BOTH shapes:
#             |    the soft deny (rc 0, empty stdout, "auto-denied" on stderr — agy 1.1.3+, and
#             |    again from 1.1.20; since 1.1.27 the envelope also names the tool in
#             |    denied_actions, measured on 1.2.0) and 1.1.13's hard error (rc 1, "user
#             |    denied permission", 1.1.13-1.1.19). Add a permissions.allow rule, or --yolo.
#             |    URL reads need a grant too since 1.1.28 (read_url(<target>), --allow-url, or --yolo).
#
# On a classifiable failure, a machine-readable line is printed to stderr so
# orchestrators (e.g. agy-job.sh) can react without scraping prose:
#   AGY_SIGNAL {"status":"QUOTA_EXHAUSTED","reason":"...","model":"...","retry":"--continue"}
#
# AGY_USAGE / AGY_SIGNAL go to stderr. If you are MEASURING cost, also set
# AGY_USAGE_LOG=/path/to/log: stderr is easily lost (`2>&1 | tail -N` keeps the
# digest and drops the usage line — see tee_usage below), a named file is not.
#
set -euo pipefail

# Claude Code injects userConfig options as CLAUDE_PLUGIN_OPTION_* into HOOKS only,
# never into Bash-tool subshells (#101). Load them from settings.json when unset.
# shellcheck source=lib/plugin-options.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/plugin-options.sh"
load_plugin_options

TIER="${CLAUDE_PLUGIN_OPTION_DEFAULT_TIER:-flash}"
TIMEOUT="${CLAUDE_PLUGIN_OPTION_TIMEOUT:-5m}"
TIER_EXPLICIT=0
MODEL=""
EFFORT=""
READ_ONLY=0
ALLOW_URL=0
CUSTOM_SETTINGS=""
JSON_SCHEMA=""
YOLO=0
SANDBOX=0
DIGEST=0
MODE=""
ADD_DIRS=()
PROMPT=""
CONTINUE=0
CONV_ID=""
ALLOW_SLASH=0
PRINT_CMD=0
DENIED_ACTIONS=""   # tool names from the envelope's denied_actions (agy 1.1.27+), for the message

die() { echo "agy-delegate: $*" >&2; exit 1; }
need() { [ "$1" -ge 2 ] || die "option '$2' needs a value"; }

# Normalize a model identifier to lowercase alphanumerics for case/punctuation-insensitive matching.
norm_model() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }

# Portable <mtime>:<size> signature following symlinks (GNU coreutils stat, else BSD stat).
file_stat_sig() {
  [ -e "$1" ] || { printf '0:0'; return 0; }
  stat -L -c '%Y:%s' "$1" 2>/dev/null || stat -L -f '%m:%z' "$1" 2>/dev/null || printf '0:0'
}

# Portable content signature (`<crc>:<bytes>` via POSIX cksum) for small JSON config files
# that agy rewrites atomically on every invocation (`cache/onboarding.json`) without changing
# content, avoiding false mtime cache invalidation across consecutive runs.
file_content_sig() {
  if [ -f "$1" ]; then
    cksum < "$1" 2>/dev/null | awk '{printf "%s:%s", $1, $2}' || printf '0:0'
  else
    printf '0:0'
  fi
}

# Warm tier-fallback cache helpers (shared format with scripts/doctor.sh).
# In auto mode, requires a real agy binary (> 65536 bytes) and no STUB_* env vars so
# unit-test stubs (< 10 KB) never read or write $HOME/.cache unless AGY_TIER_CACHE=on.
tier_cache_enabled() {
  local mode bin sig sz
  mode="$(printf '%s' "${AGY_TIER_CACHE:-auto}" | tr '[:upper:]' '[:lower:]')"
  case "$mode" in
    off|false|0|no|disabled) return 1 ;;
    on|true|1|yes|enabled)   return 0 ;;
  esac
  [ -z "${STUB_MODE:-}${STUB_REJECT_MODEL:-}" ] || return 1
  bin="$(command -v agy 2>/dev/null || true)"
  [ -n "$bin" ] || return 1
  sig="$(file_stat_sig "$bin")"
  sz="${sig#*:}"
  case "$sz" in ''|*[!0-9]*) return 1 ;; esac
  [ "$sz" -gt 65536 ]
}

tier_cache_file() {
  printf '%s/tier-models-v1.tsv' "${AGY_TIER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/antigravity-claude}"
}

tier_cache_key() {
  local bin app oauth_present="0"
  bin="$(command -v agy 2>/dev/null || true)"
  app="$HOME/.gemini/antigravity-cli"
  [ -s "$app/antigravity-oauth-token" ] && oauth_present="1"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$bin" "$(file_stat_sig "$bin")" \
    "$oauth_present" \
    "$(file_content_sig "$app/settings.json")" \
    "$(file_content_sig "$app/cache/onboarding.json")" \
    "${AGY_ADC_AUTH:-}" "${GEMINI_API_KEY:+1}" \
    "${GOOGLE_CLOUD_PROJECT:-}" "${GOOGLE_CLOUD_LOCATION:-}" | tr '\t\r\n' '   '
}

tier_cache_get() { # $1 = slot (e.g. pro or pro:medium) -> echoes cached model if fresh
  tier_cache_enabled || return 1
  local slot="$1" cf now ttl key ts k s m
  cf="$(tier_cache_file)"
  [ -f "$cf" ] || return 1
  now="$(date +%s 2>/dev/null || echo 0)"
  ttl="${AGY_TIER_CACHE_TTL:-21600}"
  case "$ttl" in ''|*[!0-9]*) ttl=21600 ;; esac
  key="$(tier_cache_key)"
  while IFS=$'\t' read -r ts k s m; do
    [ -n "$ts" ] && [ -n "$k" ] && [ -n "$s" ] && [ -n "$m" ] || continue
    case "$ts" in *[!0-9]*) continue ;; esac
    if [ "$k" = "$key" ] && [ "$s" = "$slot" ] && [ $(( now - ts )) -lt "$ttl" ]; then
      printf '%s' "$m"
      return 0
    fi
  done < "$cf"
  return 1
}

tier_cache_put() { # $1 = slot, $2 = fallback model (empty = evict)
  tier_cache_enabled || return 0
  local slot="$1" val="${2:-}" cf dir now ttl key tmp ts k s m
  cf="$(tier_cache_file)"; dir="$(dirname "$cf")"
  now="$(date +%s 2>/dev/null || echo 0)"
  ttl="${AGY_TIER_CACHE_TTL:-21600}"
  case "$ttl" in ''|*[!0-9]*) ttl=21600 ;; esac
  key="$(tier_cache_key)"
  mkdir -p -m 0700 "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/.tier-cache.XXXXXX" 2>/dev/null)" || return 0
  chmod 0600 "$tmp" 2>/dev/null || true
  if [ -f "$cf" ]; then
    while IFS=$'\t' read -r ts k s m; do
      [ -n "$ts" ] && [ -n "$k" ] && [ -n "$s" ] && [ -n "$m" ] || continue
      case "$ts" in *[!0-9]*) continue ;; esac
      [ $(( now - ts )) -lt "$ttl" ] || continue
      if [ "$k" = "$key" ] && [ "$s" = "$slot" ]; then continue; fi
      printf '%s\t%s\t%s\t%s\n' "$ts" "$k" "$s" "$m" >> "$tmp"
    done < "$cf"
  fi
  if [ -n "$val" ]; then
    printf '%s\t%s\t%s\t%s\n' "$now" "$key" "$slot" "$val" >> "$tmp"
  fi
  mv -f "$tmp" "$cf" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# Layer 1 cold-miss pruning: when agy's ValidateRequestedModel error includes an
# `Available models:` block (cli/store/model_config_manager.go), intersect remaining
# fallback candidates against those exact labels in priority order to jump in ONE hop.
# Returns:
#   0 -> matched candidate printed as `<0-based-index>\t<model>`
#   1 -> `Available models:` block WAS present, and ZERO candidates matched (abort retries -> exit 14)
#   2 -> no `Available models:` block in error (walk candidates step-by-step)
pick_available_fallback() {
  local raw="$1"; shift
  local avail=() line entry first first_lc rest in_block=0 cand cn an idx=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [ "$in_block" -eq 0 ]; then
      case "$line" in
        "Available models:"*) in_block=1 ;;
      esac
      continue
    fi
    case "$line" in
      "  "[![:space:]]*|$'\t'[![:space:]]*)
        entry="${line#"${line%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        first="${entry%%[[:space:]]*}"
        first_lc="$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')"
        rest="${entry#"$first"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        if [ -n "$rest" ] && [ "$first" = "$first_lc" ]; then
          avail+=("$(norm_model "$first")" "$(norm_model "$rest")")
        else
          avail+=("$(norm_model "$entry")")
        fi ;;
      *)
        break ;;
    esac
  done <<EOF
$raw
EOF
  [ "${#avail[@]}" -gt 0 ] || return 2
  for cand in "$@"; do
    cn="$(norm_model "$cand")"
    for an in "${avail[@]}"; do
      if [ -n "$cn" ] && [ "$cn" = "$an" ]; then
        printf '%s\t%s' "$idx" "$cand"
        return 0
      fi
    done
    idx=$(( idx + 1 ))
  done
  return 1
}

# Map canonical lowercase effort (`low|medium|high|xhigh|max`) to display-name title case.
effort_display_label() {
  case "$1" in
    low)    printf 'Low' ;;
    medium) printf 'Medium' ;;
    high)   printf 'High' ;;
    xhigh)  printf 'XHigh' ;;
    max)    printf 'Max' ;;
  esac
}

# Rewrite `(Low|Medium|High|XHigh|Max)` at the end of a display name ($1) to effort ($2).
# Returns 0 and prints the rewritten name when $1 has a parenthesized effort suffix; returns 1
# when $1 is an effortless name/slug (caller should pass `--effort` directly to agy).
rewrite_display_effort() {
  local m="$1" eff="$2" lbl prefix
  lbl="$(effort_display_label "$eff")"
  shopt -s nocasematch
  case "$m" in
    *" (low)"|*" (medium)"|*" (high)"|*" (xhigh)"|*" (max)")
      shopt -u nocasematch
      prefix="${m% (*}"
      printf '%s (%s)' "$prefix" "$lbl"
      return 0 ;;
  esac
  shopt -u nocasematch
  return 1
}

# Adapt a fallback model ($1) to a requested effort ($2), respecting per-family effort caps
# (e.g. xhigh/max caps to High on Carbon/Argon/Flash/3.1 Pro; medium maps to High on 3.1 Pro).
adapt_fallback_effort() {
  local m="$1" eff="$2" eff_use="$2"
  [ -n "$eff" ] || { printf '%s' "$m"; return 0; }
  case "$m" in
    *"Hydrogen"*)
      [ "$eff_use" = "max" ] && eff_use="xhigh" ;;
    *"3.1 Pro ("*)
      case "$eff_use" in low) eff_use="low" ;; *) eff_use="high" ;; esac ;;
    *"Carbon"*|*"Argon"*|*"Flash ("*)
      case "$eff_use" in xhigh|max) eff_use="high" ;; esac ;;
  esac
  rewrite_display_effort "$m" "$eff_use" || printf '%s' "$m"
}

# True when an agy error blob says the requested --model does not exist or is unavailable
# on this plan/project/location. ONE definition, used by both the exit-14 classifier and
# the tier fallback trigger (#104): if agy rewords the message, both move together.
model_unavailable_blob() {
  shopt -s nocasematch
  case "$1" in
    *"invalid --model"*|*"is not recognized as a known model"*|*"not a known model"*|\
    *"is unavailable:"*|*"is currently available to"*|*"is no longer available"*|\
    *"model was not found, or your project does not have access"*|\
    *"model is not supported in the selected location"*)
      shopt -u nocasematch; return 0 ;;
  esac
  shopt -u nocasematch; return 1
}

# True when agy's own --print-timeout cut the turn off (mid-turn or while waiting on
# non-daemon background tasks). Covers both agy 1.1.28–1.4.x (rc 0 + `[agy] print timeout...`
# on stderr) and agy >= 1.5.0 (#115: rc 3 + `finished_reason: "print_timeout"` in the JSON
# envelope, `AGY_ERROR: {..."reason":"print_timeout"...}` on stderr, and the `[agy]` stderr
# prefix for both mid-turn and background-task timeouts).
is_print_timeout() {
  [ "${JSON_FINISHED:-}" = "print_timeout" ] && return 0
  [ -s "$ERR" ] || return 1
  grep -qE '^AGY_ERROR: \{.*[,{]"reason": *"print_timeout"[,}]|^\[agy\] print timeout after [^ ]+ with (turn in progress; returning partial output|[0-9]+ background task\(s\) still running; terminating them)'$'\r''?$' "$ERR" 2>/dev/null
}

# Optional side channel for AGY_USAGE / AGY_SIGNAL.
USAGE_LOG="${AGY_USAGE_LOG:-${CLAUDE_PLUGIN_OPTION_USAGE_LOG:-}}"
USAGE_LOG_WARNED=0
tee_usage() { # $1 = the full line, already formatted
  [ -n "$USAGE_LOG" ] || return 0
  local dir
  dir="$(dirname "$USAGE_LOG")"
  if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
    if printf '%s\n' "$1" 2>/dev/null >>"$USAGE_LOG"; then
      return 0
    fi
  fi
  if [ "$USAGE_LOG_WARNED" -eq 0 ]; then
    USAGE_LOG_WARNED=1
    echo "agy-delegate: usage log not writable: $USAGE_LOG" >&2
  fi
}

# Emit a one-line machine-readable failure signal to stderr. $1=status $2=reason.
signal() {
  local status="$1" reason="$2" retry="" line
  [ "$status" = "QUOTA_EXHAUSTED" ] && retry="--continue"
  reason="$(printf '%s' "$reason" | tr '\n\r\t' '   ' | tr -d '"\\' | cut -c1-200)"
  line="$(printf 'AGY_SIGNAL {"status":"%s","reason":"%s","model":"%s","retry":"%s"}' \
    "$status" "$reason" "${MODEL:-}" "$retry")"
  printf '%s\n' "$line" >&2
  tee_usage "$line"
}

permission_denied() {   # $1 = "shown" when the caller already echoed $ERR
  if [ "${1:-}" != shown ] && [ -s "$ERR" ]; then
    cat "$ERR" >&2
  fi
  if [ "${YOLO:-0}" -eq 1 ]; then
    echo "agy-delegate: agy denied a tool even though --yolo (--dangerously-skip-permissions) was passed${DENIED_ACTIONS:+ — denied: $DENIED_ACTIONS} — blocked by policy and not performed. On agy 1.5.2+, Gemini Enterprise admin policy (enforce_unsandboxed_command_review, enforce_outside_workspace_file_review, or an admin permissionPreset), explicit permissions.deny rules, and the system command denylist override --dangerously-skip-permissions in headless mode. Keep file/command targets inside the workspace (--dir), inspect resolved rules with agy-doctor, or check your organization's admin policy." >&2
    signal PERMISSION_DENIED "policy_blocked: agy denied a tool despite --yolo${DENIED_ACTIONS:+ (denied: $DENIED_ACTIONS)} — blocked by enterprise admin policy or permissions.deny"
  else
    echo "agy-delegate: agy denied a tool that needs permission (headless can't prompt)${DENIED_ACTIONS:+ — denied: $DENIED_ACTIONS} — the denied action was not performed. For a FILE WRITE, use a permissions.allow rule covering the target in ~/.gemini/antigravity-cli/settings.json — write_file(<dir>) matches recursively beneath <dir> — or on agy 1.5.7+ pass --mode accept-edits for in-workspace writes (measured on agy 1.1.13–1.5.6, --mode accept-edits was NOT a headless write grant and was denied like a plain write; it never grants shell commands); --yolo also works and approves ALL tools. For a URL READ pass --allow-url or add read_url(<target>) (agy 1.1.28+). Other tools (web search / Vertex AI Search / terminal) need --yolo unless a rule covers them. If a rule is ALREADY in place, run agy-doctor to verify it parses." >&2
    signal PERMISSION_DENIED "agy denied a permissioned tool in headless${DENIED_ACTIONS:+ (denied: $DENIED_ACTIONS)} — add a permissions.allow rule or pass --yolo"
  fi
  exit 15
}

# Print the header comment between "# Usage:" and "# Exit codes:".
usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- map a tier to an exact agy model name (see `agy models`) ---
# Primary 3-tier Gemini 4 lineup: flash = Hydrogen (High), flash-lo = Hydrogen (Low),
# pro = Carbon (High); plus power/cost aliases argon and flash-38.
model_for_tier() {
  case "$1" in
    flash)         echo "${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-Gemini 4 Hydrogen (High)}" ;;
    flash-lo|lite) echo "${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-Gemini 4 Hydrogen (Low)}" ;;
    pro)           echo "${CLAUDE_PLUGIN_OPTION_TIER_PRO:-Gemini 4 Carbon (High)}" ;;
    argon)         echo "${CLAUDE_PLUGIN_OPTION_TIER_ARGON:-Gemini 4 Argon (High)}" ;;
    flash-38)      echo "${CLAUDE_PLUGIN_OPTION_TIER_FLASH_38:-Gemini 3.8 Flash (High)}" ;;
    *) die "unknown tier '$1' (use flash | flash-lo | lite | pro | argon | flash-38)" ;;
  esac
}

on_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }

on_windows_native() {
  case "${OSTYPE:-}" in msys*|cygwin*|win32) return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

timeout_cmd() {
  if command -v timeout  >/dev/null 2>&1; then echo timeout;  return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then echo gtimeout; return 0; fi
  return 1
}

outer_timeout_secs() {
  local d="${1:-5m}" n unit secs min_pad
  n="${d%[smh]}"; unit="${d#"$n"}"
  case "$n" in (*[!0-9]*|'') n=300; unit=s ;; esac
  case "$unit" in
    h) secs=$(( n * 3600 )) ;;
    m) secs=$(( n * 60 )) ;;
    s|'') secs=$(( n )) ;;
    *) secs=$(( n )) ;;
  esac
  [ "$secs" -eq 0 ] && { echo 0; return 0; }
  min_pad="${_AGY_OUTER_MIN_PAD:-35}"
  case "$min_pad" in (*[!0-9]*|'') min_pad=35 ;; esac
  local pad=$(( secs / 4 ))
  [ "$pad" -lt "$min_pad" ] && pad="$min_pad"
  [ "$pad" -gt 120 ] && pad=120
  echo $(( secs + pad ))
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tier)          need "$#" "$1"; TIER="$2"; TIER_EXPLICIT=1; shift 2 ;;
    -e|--effort)        need "$#" "$1"; EFFORT="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2
                        case "$EFFORT" in low|medium|high|xhigh|max) ;;
                          *) die "invalid --effort '$EFFORT' (use low | medium | high | xhigh | max)" ;;
                        esac ;;
    -d|--dir|--add-dir) need "$#" "$1"; ADD_DIRS+=("$2"); shift 2 ;;
    --timeout)          need "$#" "$1"; TIMEOUT="$2"; shift 2 ;;
    --read-only)        READ_ONLY=1; shift ;;
    --allow-url)        READ_ONLY=1; ALLOW_URL=1; shift ;;
    --settings)         need "$#" "$1"; CUSTOM_SETTINGS="$2"; shift 2 ;;
    --json-schema)      need "$#" "$1"; JSON_SCHEMA="$2"; shift 2 ;;
    --yolo)             YOLO=1; shift ;;
    --sandbox)          SANDBOX=1; shift ;;
    --digest)           DIGEST=1; shift ;;
    --mode)             need "$#" "$1"; MODE="$2"; shift 2
                        case "$MODE" in accept-edits|plan|auto) ;;
                          *) die "invalid --mode '$MODE' (use accept-edits | plan | auto; agy >= 1.1.0, auto >= 1.3.5)" ;;
                        esac ;;
    -c|--continue)      CONTINUE=1; shift ;;
    --conversation)     need "$#" "$1"; CONV_ID="$2"; shift 2 ;;
    -m|--model)         need "$#" "$1"; MODEL="$2"; shift 2 ;;
    --allow-slash-commands) ALLOW_SLASH=1; shift ;;
    --print-command)    PRINT_CMD=1; shift ;;
    -h|--help)          usage ;;
    -)                  PROMPT="$(cat)"; shift ;;
    --)                 shift; PROMPT="${*:-}"; break ;;
    -*)                 die "unknown option '$1'" ;;
    *)                  PROMPT="$*"; break ;;
  esac
done

[ -n "$PROMPT" ] || die "no prompt given (pass a string, or '-' to read stdin)"
if [ "$PRINT_CMD" -ne 1 ] && ! command -v agy >/dev/null 2>&1; then
  echo "agy-delegate: 'agy' not found on PATH — install the Antigravity CLI first" >&2
  signal AGY_MISSING "agy not on PATH"
  exit 13
fi

# Resolve the executor model. Precedence:
#   --model > explicit --tier > userConfig default_model > default tier (mapped).
USAGE_TIER=""
if [ -z "$MODEL" ]; then
  if [ "$TIER_EXPLICIT" -eq 1 ]; then
    MODEL="$(model_for_tier "$TIER")"
    USAGE_TIER="$TIER"
  elif [ -n "${CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL:-}" ]; then
    MODEL="$CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL"
  else
    case "$TIER" in
      flash|flash-lo|lite|pro|argon|flash-38) ;;
      *) echo "agy-delegate: invalid default tier '$TIER' (set CLAUDE_PLUGIN_OPTION_DEFAULT_TIER to flash|flash-lo|pro); using flash" >&2; TIER="flash" ;;
    esac
    MODEL="$(model_for_tier "$TIER")"
    USAGE_TIER="$TIER"
  fi
fi
[ "$USAGE_TIER" = "lite" ] && USAGE_TIER="flash-lo"

# Apply --effort: when $MODEL carries a parenthesized display-name effort suffix
# (e.g. "Gemini 4 Hydrogen (High)"), rewrite the suffix directly (`agy` rejects --effort
# on non-gateway display names); otherwise pass `--effort` through to `agy` (base slugs,
# custom models, or gateway models).
PASS_RAW_EFFORT=0
if [ -n "$EFFORT" ]; then
  if REWRITTEN_MODEL="$(rewrite_display_effort "$MODEL" "$EFFORT")"; then
    MODEL="$REWRITTEN_MODEL"
  else
    PASS_RAW_EFFORT=1
  fi
fi

# WSL gotcha: agy reads --add-dir over the /mnt/* Windows mount via a slow 9p bridge.
if on_wsl; then
  for d in "${ADD_DIRS[@]:-}"; do
    [ -n "$d" ] || continue
    case "$d" in
      /mnt/*) echo "agy-delegate: note: --add-dir '$d' is on a Windows mount under WSL; agy reads it over a slow 9p bridge (calls can take 20s+). Move the repo into the Linux FS (~) for ~10x faster I/O." >&2; break ;;
    esac
  done
fi

# Heads-up: a likely write task with no visible write grant (--yolo or agy 1.5.7+ --mode accept-edits).
# Suppress when --read-only is explicitly requested.
if [ "$YOLO" -eq 0 ] && [ "$MODE" != "accept-edits" ] && [ "$READ_ONLY" -eq 0 ] && [ "$PRINT_CMD" -ne 1 ]; then
  shopt -s nocasematch
  case "$PROMPT" in
    *implement*|*scaffold*|*migrate*|*refactor*|*"write the file"*|*"create the file"*|*"edit the file"*)
      echo "agy-delegate: note: this looks like a write task and no explicit write grant (--yolo or, on agy 1.5.7+, --mode accept-edits) is set. Without a write grant, headless agy will NOT touch your workspace (issue #10). Grants that work: a permissions.allow rule matching the target — write_file(<dir>), a recursive prefix, in ~/.gemini/antigravity-cli/settings.json — which needs no flag; --mode accept-edits on agy 1.5.7+ (workspace write_file only, no terminal; denied on 1.1.13–1.5.6); or --yolo, which auto-approves ALL tools. Verify with agy-doctor and git status." >&2 ;;
  esac
  shopt -u nocasematch
fi

# --digest: append an explicit output contract so agy returns a compact digest.
if [ "$DIGEST" -eq 1 ]; then
  PROMPT="$PROMPT

OUTPUT CONTRACT (digest): reply with ONLY a compact digest — short bullets (findings / decisions / errors, with file:line references where useful). NO full file contents, NO raw logs, NO long code blocks. End with exactly one line: DIGEST: <one-sentence summary>."
fi

TO_CMD="$(timeout_cmd || true)"

# One trap for every temp file this script makes, installed before the first one exists.
HELPF=""; ERR=""; OUTF=""; RESP=""; JERR=""; JRAWERR=""; JDEN=""; PROMPTF=""
trap 'rm -f "$HELPF" "$ERR" "$OUTF" "$RESP" "$JERR" "$JRAWERR" "$JDEN" "$PROMPTF" 2>/dev/null' EXIT

HELP_OUT=""
if [ "$PRINT_CMD" -ne 1 ]; then
  HELPF="$(mktemp "${TMPDIR:-/tmp}/agy-help.XXXXXX")"
  if [ -n "$TO_CMD" ]; then
    "$TO_CMD" --kill-after=5 10 agy --help >"$HELPF" 2>&1 || true
  else
    agy --help >"$HELPF" 2>&1 || true
  fi
  HELP_OUT="$(cat "$HELPF" 2>/dev/null || true)"; rm -f "$HELPF"
fi

# --- assemble agy args ---
# Keep `--model "$MODEL"` at ARGS[0..1] so the fallback loop can update ARGS[1] in place,
# and keep `-p "$PROMPT"` strictly last for short prompts (agy 1.1.18 flag ordering).
ARGS=(--model "$MODEL" --print-timeout "$TIMEOUT")
[ "$PASS_RAW_EFFORT" -eq 1 ] && ARGS+=(--effort "$EFFORT")
for d in "${ADD_DIRS[@]:-}"; do [ -n "$d" ] && ARGS+=(--add-dir "$d"); done
[ "$YOLO" -eq 1 ]      && ARGS+=(--dangerously-skip-permissions)
[ -n "$MODE" ]         && ARGS+=(--mode "$MODE")
[ "$SANDBOX" -eq 1 ]   && ARGS+=(--sandbox)
[ "$CONTINUE" -eq 1 ]  && ARGS+=(--continue)
[ -n "$CONV_ID" ]      && ARGS+=(--conversation "$CONV_ID")
[ -n "$JSON_SCHEMA" ]  && ARGS+=(--json-schema "$JSON_SCHEMA")

# Ephemeral session settings (`--settings`, agy >= 1.4.10):
# - Explicit `--settings <json>` wins; errors clearly if the installed agy lacks `--settings`.
# - `--read-only` (`--allow-url`) injects `toolPermission="request-review"` + `agentMode=""`
#   when agy supports `--settings`; on agy < 1.4.10 (before 1.5.7 default Auto mode existed),
#   omit `--settings` cleanly and NEVER inject `--mode plan`.
if [ -n "$CUSTOM_SETTINGS" ]; then
  if [ "$PRINT_CMD" -eq 1 ]; then
    ARGS+=(--settings "$CUSTOM_SETTINGS")
  else
    case "$HELP_OUT" in
      *--settings*) ARGS+=(--settings "$CUSTOM_SETTINGS") ;;
      *) die "--settings requires agy >= 1.4.10 (current agy --help does not advertise --settings)" ;;
    esac
  fi
elif [ "$READ_ONLY" -eq 1 ]; then
  # Under `toolPermission: "request-review"`, agy auto-grants `read_file(<wsPath>)` for cwd
  # and every `--add-dir` (`PermissionGrantsFor`), while `read_file(*)` would match `*` across
  # the entire host filesystem (`CoversPath`). On Gemini Enterprise / Gateway accounts running
  # Permissions V1 (`!PermissionsV2`), `ApplySettingsToConfig` also appends `write_file(<wsPath>)`
  # into `effectiveGrants.Allow` — add `"ask":["write_file(*)","command(*)"]` (`Ask > Allow`) so
  # headless mode soft-denies both workspace writes and shell commands across V1 and V2 alike.
  if [ "$ALLOW_URL" -eq 1 ]; then
    RO_SETTINGS='{"agentMode":"","toolPermission":"request-review","permissions":{"allow":["read_url(*)"],"ask":["write_file(*)","command(*)"]}}'
  else
    RO_SETTINGS='{"agentMode":"","toolPermission":"request-review","permissions":{"allow":[],"ask":["write_file(*)","command(*)"]}}'
  fi
  if [ "$PRINT_CMD" -eq 1 ]; then
    ARGS+=(--settings "$RO_SETTINGS")
  else
    case "$HELP_OUT" in
      *--settings*) ARGS+=(--settings "$RO_SETTINGS") ;;
    esac
  fi
fi

# Suppress slash-command / skill expansion on delegated prose by default unless MODE=plan
# or `--allow-slash-commands` was passed.
if [ "$ALLOW_SLASH" -eq 0 ] && [ "$MODE" != "plan" ]; then
  case "$HELP_OUT" in
    *--disable-slash-commands*) ARGS+=(--disable-slash-commands) ;;
  esac
fi

JSON_MODE=0
raw_so="${CLAUDE_PLUGIN_OPTION_STRUCTURED_OUTPUT:-on}"
case "$(printf '%s' "$raw_so" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
  off|false|0|no|disabled) ;;
  *)
    if [ "$PRINT_CMD" -ne 1 ] && command -v python3 >/dev/null 2>&1; then
      case "$HELP_OUT" in
        *--output-format*) JSON_MODE=1; ARGS+=(--output-format json) ;;
      esac
    fi ;;
esac

# --- dry run: print the resolved (shell-quoted) agy invocation and exit ---
if [ "$PRINT_CMD" -eq 1 ]; then
  { printf 'agy'; printf ' %q' "${ARGS[@]}" -p "$PROMPT"; printf '\n'; }
  exit 0
fi

# --- run (detach stdin for short prompts; use a temp file above 64 KB) ---
PROMPT_VIA_STDIN=0
if [ "${#PROMPT}" -gt 20000 ]; then
  prompt_bytes="$(LC_ALL=C; printf '%s' "${#PROMPT}")"
  if [ "$prompt_bytes" -gt 65536 ]; then
    PROMPTF="$(mktemp "${TMPDIR:-/tmp}/agy-prompt.XXXXXX")"
    printf '%s' "$PROMPT" >"$PROMPTF"
    PROMPT_VIA_STDIN=1
  fi
fi

ERR="$(mktemp "${TMPDIR:-/tmp}/agy-delegate.XXXXXX")"
OUTF="$(mktemp "${TMPDIR:-/tmp}/agy-out.XXXXXX")"

TO_SECS="$(outer_timeout_secs "$TIMEOUT")"

if on_windows_native && [ -z "$TO_CMD" ]; then
  echo "agy-delegate: WARNING — native Windows without GNU \`timeout\`/\`gtimeout\` on PATH." >&2
  echo "agy-delegate:   headless \`agy -p\` can hang here with a 0-byte log (no ConPTY). If this" >&2
  echo "agy-delegate:   call never returns, run from WSL/macOS/Linux, or install coreutils \`timeout\`." >&2
fi

# Build Stage B plan-unavailability fallback chain for unremapped tiers (#104 + 0.31.0 Gemini 4):
# - Layer 2 (warm cache): if a fresh cached fallback exists for this binary + auth signature,
#   start directly on the cached model with 0s cold-miss penalty.
# - Layer 1 (cold miss): if ValidateRequestedModel fails and includes `Available models:`,
#   jump in ONE hop to the highest-priority offered fallback instead of walking dead options.
PRIMARY_MODEL="$MODEL"
CACHE_SLOT="${USAGE_TIER}${EFFORT:+:$EFFORT}"
BASE_FALLBACKS=()
TIER_FALLBACK_MODELS=()
USED_CACHED_FALLBACK=0

raw_fb_cands=()
case "$USAGE_TIER" in
  pro)
    if [ -z "${CLAUDE_PLUGIN_OPTION_TIER_PRO:-}" ]; then
      raw_fb_cands=("Gemini 4 Argon (High)" "Gemini 3.1 Pro" "Gemini 3.1 Pro (High)" "Gemini 3.1 Pro (Low)" "Gemini 4 Hydrogen (High)" "Gemini 3.8 Flash (High)")
    fi ;;
  flash)
    if [ -z "${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-}" ]; then
      raw_fb_cands=("Gemini 3.8 Flash (High)" "Gemini 3.7 Flash (High)" "Gemini 3.6 Flash (High)" "Gemini 3.5 Flash")
    fi ;;
  flash-lo)
    if [ -z "${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-}" ]; then
      raw_fb_cands=("Gemini 3.8 Flash (Low)" "Gemini 3.5 Flash Lite" "Gemini 3.7 Flash (Low)" "Gemini 3.1 Flash Lite")
    fi ;;
  argon)
    if [ -z "${CLAUDE_PLUGIN_OPTION_TIER_ARGON:-}" ]; then
      raw_fb_cands=("Gemini 3.1 Pro" "Gemini 3.1 Pro (High)" "Gemini 3.1 Pro (Low)" "Gemini 3.8 Flash (High)")
    fi ;;
  flash-38)
    if [ -z "${CLAUDE_PLUGIN_OPTION_TIER_FLASH_38:-}" ]; then
      raw_fb_cands=("Gemini 3.7 Flash (High)" "Gemini 3.6 Flash (High)")
    fi ;;
esac

for cand in "${raw_fb_cands[@]:-}"; do
  [ -n "$cand" ] || continue
  adapted="$(adapt_fallback_effort "$cand" "$EFFORT")"
  [ "$adapted" = "$PRIMARY_MODEL" ] && continue
  dup=0
  for prev in "${BASE_FALLBACKS[@]:-}"; do
    [ "$prev" = "$adapted" ] && { dup=1; break; }
  done
  [ "$dup" -eq 0 ] && BASE_FALLBACKS+=("$adapted")
done
if [ "${#BASE_FALLBACKS[@]}" -gt 0 ]; then
  TIER_FALLBACK_MODELS=("${BASE_FALLBACKS[@]}")
  if CACHED_FB="$(tier_cache_get "$CACHE_SLOT")" && [ -n "$CACHED_FB" ] && [ "$CACHED_FB" != "$PRIMARY_MODEL" ]; then
    MODEL="$CACHED_FB"
    ARGS[1]="$MODEL"
    USED_CACHED_FALLBACK=1
    # Keep remaining fallbacks + primary in reserve in case the plan changed since caching.
    TIER_FALLBACK_MODELS=("$PRIMARY_MODEL")
    for fb_item in "${BASE_FALLBACKS[@]}"; do
      [ "$fb_item" = "$CACHED_FB" ] || TIER_FALLBACK_MODELS+=("$fb_item")
    done
    echo "agy-delegate: $USAGE_TIER fell back to $MODEL (cached; $PRIMARY_MODEL not on this plan)" >&2
  fi
fi

while :; do
  set +e
  if [ "$PROMPT_VIA_STDIN" -eq 1 ]; then
    if [ -n "$TO_CMD" ] && [ "$TO_SECS" -gt 0 ]; then
      "$TO_CMD" --kill-after=10 "$TO_SECS" agy "${ARGS[@]}" < "$PROMPTF" >"$OUTF" 2>"$ERR"
      RC=$?
    else
      agy "${ARGS[@]}" < "$PROMPTF" >"$OUTF" 2>"$ERR"
      RC=$?
    fi
  else
    if [ -n "$TO_CMD" ] && [ "$TO_SECS" -gt 0 ]; then
      "$TO_CMD" --kill-after=10 "$TO_SECS" agy "${ARGS[@]}" -p "$PROMPT" < /dev/null >"$OUTF" 2>"$ERR"
      RC=$?
    else
      agy "${ARGS[@]}" -p "$PROMPT" < /dev/null >"$OUTF" 2>"$ERR"
      RC=$?
    fi
  fi
  OUT="$(cat "$OUTF" 2>/dev/null)"
  set -e

  # --- unwrap the structured envelope (JSON mode) --------------------------------
  JSON_STATUS=""; JSON_FINISHED=""; JSON_ERROR=""; JSON_RAW_ERROR=""; JSON_DENIED=""; meta=""
  if [ "$JSON_MODE" -eq 1 ] && [[ "$OUT" = *[!$' \t\n\r']* ]]; then
    RESP="$(mktemp "${TMPDIR:-/tmp}/agy-resp.XXXXXX")"
    JERR="$(mktemp "${TMPDIR:-/tmp}/agy-err.XXXXXX")"
    JRAWERR="$(mktemp "${TMPDIR:-/tmp}/agy-rawerr.XXXXXX")"
    JDEN="$(mktemp "${TMPDIR:-/tmp}/agy-den.XXXXXX")"
    meta="$(AGY_JSON="$OUT" AGY_RESP_FILE="$RESP" AGY_ERR_FILE="$JERR" AGY_RAWERR_FILE="$JRAWERR" AGY_DEN_FILE="$JDEN" \
          AGY_MODEL="$MODEL" AGY_TIER="$USAGE_TIER" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
raw = os.environ.get("AGY_JSON", "")
try:
    # strict=False: agy 1.1.8 leaves raw newlines inside "response".
    d = json.loads(raw, strict=False)
    if not isinstance(d, dict): raise ValueError
except Exception:
    sys.exit(1)
resp = str(d.get("response", "") or "")
# `--json-schema` populates `.structured_output` while `.response` can be empty.
if not resp.strip() and "structured_output" in d and d.get("structured_output") is not None:
    so = d.get("structured_output")
    resp = so if isinstance(so, str) else json.dumps(so, ensure_ascii=False)
with open(os.environ["AGY_RESP_FILE"], "w", encoding="utf-8") as fh:
    fh.write(resp)
raw_err = str(d.get("error", "") or "")
with open(os.environ["AGY_RAWERR_FILE"], "w", encoding="utf-8") as fh:
    fh.write(raw_err)
with open(os.environ["AGY_ERR_FILE"], "w", encoding="utf-8") as fh:
    fh.write(" ".join(raw_err.split()))
den = d.get("denied_actions") or []
names = []
for a in den if isinstance(den, list) else []:
    n = a.get("action") or a.get("display_name") if isinstance(a, dict) else a
    if n: names.append(" ".join(str(n).split()))
with open(os.environ["AGY_DEN_FILE"], "w", encoding="utf-8") as fh:
    fh.write(" ".join(names))
u = d.get("usage") or {}
def n(k):
    v = u.get(k)
    return v if isinstance(v, int) else 0
def top(k):
    v = d.get(k)
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0
one_line = lambda s: " ".join(str(s or "").split())
out_meta = {
    "status": str(d.get("status", "")),
    "error": one_line(raw_err),
    "usage": {"input": n("input_tokens"), "output": n("output_tokens"),
              "thinking": n("thinking_tokens"), "cache_read": n("cache_read_tokens"),
              "total": n("total_tokens")},
    "conversation_id": str(d.get("conversation_id", "") or ""),
    "model": os.environ.get("AGY_MODEL", ""),
    "tier": os.environ.get("AGY_TIER", ""),
    "duration_seconds": top("duration_seconds"),
    "num_turns": top("num_turns"),
}
fr = one_line(d.get("finished_reason", ""))
if fr:
    out_meta["finished_reason"] = fr
print(json.dumps(out_meta))
PY
)"
    if [ -n "$meta" ]; then
      JSON_STATUS="$(printf '%s' "$meta" | sed -n 's/.*"status": *"\([^"]*\)".*/\1/p')"
      JSON_FINISHED="$(printf '%s' "$meta" | sed -n 's/.*"finished_reason": *"\([a-z_]*\)".*/\1/p')"
      JSON_ERROR="$(cat "$JERR" 2>/dev/null)"
      JSON_RAW_ERROR="$(cat "$JRAWERR" 2>/dev/null)"
      JSON_DENIED="$(cat "$JDEN" 2>/dev/null)"
      OUT="$(cat "$RESP" 2>/dev/null)"
      [ "$JSON_STATUS" = "ERROR" ] && [ "$RC" -eq 0 ] && RC=1
    fi
    rm -f "$RESP" "$JERR" "$JRAWERR" "$JDEN"
  fi

  if [ "$RC" -ne 0 ] && [ "${#TIER_FALLBACK_MODELS[@]}" -gt 0 ] && ! is_print_timeout; then
    probe_blob="$(cat "$ERR" 2>/dev/null)"
    [ -n "$JSON_ERROR" ] && probe_blob="$JSON_ERROR
$probe_blob"
    if model_unavailable_blob "$probe_blob"; then
      if [ "$USED_CACHED_FALLBACK" -eq 1 ]; then
        tier_cache_put "$CACHE_SLOT" ""
        USED_CACHED_FALLBACK=0
      fi
      raw_avail_blob="$(cat "$ERR" 2>/dev/null)"
      [ -n "$JSON_RAW_ERROR" ] && raw_avail_blob="$JSON_RAW_ERROR
$raw_avail_blob"
      set +e
      picked_fb="$(pick_available_fallback "$raw_avail_blob" "${TIER_FALLBACK_MODELS[@]}")"
      pick_rc=$?
      set -e
      if [ "$pick_rc" -eq 0 ]; then
        pick_idx="${picked_fb%%$'\t'*}"
        MODEL="${picked_fb#*$'\t'}"
        next_idx=$(( pick_idx + 1 ))
        if [ "$next_idx" -lt "${#TIER_FALLBACK_MODELS[@]}" ]; then
          TIER_FALLBACK_MODELS=("${TIER_FALLBACK_MODELS[@]:$next_idx}")
        else
          TIER_FALLBACK_MODELS=()
        fi
        ARGS[1]="$MODEL"
        echo "agy-delegate: $USAGE_TIER fell back to $MODEL ($PRIMARY_MODEL not on this plan)" >&2
        continue
      elif [ "$pick_rc" -eq 1 ]; then
        # `Available models:` was authoritative and contained NONE of our fallbacks — fail fast.
        TIER_FALLBACK_MODELS=()
      else
        MODEL="${TIER_FALLBACK_MODELS[0]}"
        if [ "${#TIER_FALLBACK_MODELS[@]}" -gt 1 ]; then
          TIER_FALLBACK_MODELS=("${TIER_FALLBACK_MODELS[@]:1}")
        else
          TIER_FALLBACK_MODELS=()
        fi
        ARGS[1]="$MODEL"
        echo "agy-delegate: $USAGE_TIER fell back to $MODEL ($PRIMARY_MODEL not on this plan)" >&2
        continue
      fi
    fi
  fi
  break
done

# Persist or refresh warm fallback cache once a tier run succeeds.
if [ "$RC" -eq 0 ] && [ "${#BASE_FALLBACKS[@]}" -gt 0 ]; then
  if [ "$MODEL" != "$PRIMARY_MODEL" ]; then
    tier_cache_put "$CACHE_SLOT" "$MODEL"
  elif [ "$USED_CACHED_FALLBACK" -eq 1 ]; then
    tier_cache_put "$CACHE_SLOT" ""
  fi
fi

if [ -n "$meta" ]; then
  printf 'AGY_USAGE %s\n' "$meta" >&2
  tee_usage "AGY_USAGE $meta"
fi

# `timeout` exits 124 (SIGTERM) or 137 (SIGKILL after --kill-after) when it had to
# kill agy. Treat that as our structured TIMEOUT (exit 12), not a generic failure.
if [ -n "$TO_CMD" ] && [ "$TO_SECS" -gt 0 ] && { [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; } \
   && [ "$JSON_STATUS" = "SUCCESS" ] && [ -z "$JSON_FINISHED" ] && ! is_print_timeout && [[ "$OUT" = *[!$' \t\n\r']* ]]; then
  echo "agy-delegate: agy wrote a complete result but did not exit; killed by the wall-clock guard (${TO_SECS}s). See https://github.com/google-antigravity/antigravity-cli/issues/1313" >&2
  RC=0
fi
if [ -n "$TO_CMD" ] && [ "$TO_SECS" -gt 0 ] && { [ $RC -eq 124 ] || [ $RC -eq 137 ]; } && ! is_print_timeout; then
  echo "agy-delegate: agy hit the wall-clock guard (${TO_SECS}s) and was terminated — likely a headless/no-TTY hang." >&2
  if on_windows_native; then
    echo "agy-delegate:   native Windows: agy needs a console (ConPTY); run delegation from WSL/macOS/Linux." >&2
  fi
  signal TIMEOUT "agy wall-clock guard fired after ${TO_SECS}s (headless/no-TTY hang?)"
  exit 12
fi

if [ -n "$JSON_DENIED" ]; then
  DENIED_ACTIONS="$JSON_DENIED"
  if [[ "$OUT" = *[!$' \t\n\r']* ]]; then printf '%s\n' "$OUT"; fi
  permission_denied
fi

case "$RC" in
  0|1|3|124|137)
    if is_print_timeout; then
      has_partial=0
      if [[ "$OUT" = *[!$' \t\n\r']* ]]; then
        has_partial=1
        printf '%s\n' "$OUT"
      fi
      [ -s "$ERR" ] && cat "$ERR" >&2
      usage_note=""; [ "$JSON_MODE" -eq 1 ] && usage_note="; AGY_USAGE above omits the unfinished step"
      if [ "$has_partial" -eq 1 ]; then
        out_note="the output above is PARTIAL"
        sig_note="partial output printed to stdout"
      else
        out_note="no output was produced before expiry (PARTIAL turn)"
        sig_note="no output produced before expiry"
      fi
      echo "agy-delegate: agy's --print-timeout ($TIMEOUT) expired — ${out_note} (agy 1.1.28–1.4.x exits 0; agy 1.5.0+ exits 3${usage_note}). Raise --timeout or narrow the task; --continue resumes the same conversation." >&2
      signal TIMEOUT "agy print-timeout ($TIMEOUT) expired — ${sig_note}"
      exit 12
    fi ;;
esac

if [ $RC -ne 0 ]; then
  echo "agy-delegate: agy exited $RC" >&2
  [ -s "$ERR" ] && cat "$ERR" >&2
  [ -n "$JSON_ERROR" ] && printf '%s\n' "$JSON_ERROR" >&2
  blob="$(cat "$ERR" 2>/dev/null)"
  [ -n "$JSON_ERROR" ] && blob="$JSON_ERROR
$blob"
  shopt -s nocasematch
  case "$blob" in
    *"user denied permission"*|*"permission check failed"*|*"auto-denied"*|\
    *"permission that headless"*|*"dangerously-skip-permissions"*)
      shopt -u nocasematch; permission_denied shown ;;
  esac
  shopt -u nocasematch
  if model_unavailable_blob "$blob"; then
    echo "agy-delegate: model '$MODEL' is not available on this plan — run \`agy models\`, then fix --model / the tier_* / default_model option." >&2
    signal MODEL_UNAVAILABLE "model not in \`agy models\` (check --model / tier remaps)"; exit 14
  fi
  shopt -s nocasematch
  case "$blob" in
    *quota*|*"rate limit"*|*"resource exhausted"*|*"credits balance is too low"*|\
    *"insufficient credits"*|*"spend cap"*|*"spend cap breached"*|*monetization_denied*|\
    *"individual quota reached"*|*"ai.studio/spend"*|*"billing#prepay"*)
      shopt -u nocasematch; signal QUOTA_EXHAUSTED "agy quota / rate limit / spend cap"; exit 10 ;;
    *unauthenticated*|*unauthorized*|*"sign in"*|*"please authenticate"*|*reauth*|\
    *"gemini_api_key environment variable is not set"*|*"authentication required"*)
      shopt -u nocasematch; signal AUTH_REQUIRED "agy not authenticated — run \`agy\` or \`agy acp --login\` (or set GEMINI_API_KEY)"; exit 11 ;;
    *"timed out"*|*"deadline exceeded"*|*"print-timeout"*|*"timeout waiting for cascade"*)
      shopt -u nocasematch; signal TIMEOUT "agy print-timeout / deadline exceeded"; exit 12 ;;
  esac
  shopt -u nocasematch
  signal AGY_FAILED "agy exited $RC"
  exit 2
fi
if [[ "$OUT" != *[!$' \t\n\r']* ]]; then
  eblob="$(cat "$ERR" 2>/dev/null)"
  shopt -s nocasematch
  case "$eblob" in
    *"auto-denied"*|*"permissions.allow"*|*"permission that headless"*|*"dangerously-skip-permissions"*)
      shopt -u nocasematch
      permission_denied ;;
  esac
  shopt -u nocasematch
  echo "agy-delegate: agy returned empty output (model='$MODEL')" >&2
  exit 3
fi

WARN_CHARS="${CLAUDE_PLUGIN_OPTION_DIGEST_WARN_CHARS:-8000}"
case "$WARN_CHARS" in (*[!0-9]*|'') WARN_CHARS=8000 ;; esac
if [ "$WARN_CHARS" -gt 0 ] && [ "${#OUT}" -gt "$WARN_CHARS" ]; then
  echo "agy-delegate: note: output is ${#OUT} chars (> ${WARN_CHARS}) — that looks like a raw dump, not a digest. Don't ingest this into the conductor's context: re-run with --digest, or have agy summarize it first. (plugin option digest_warn_chars tunes this; 0 disables.)" >&2
fi

printf '%s\n' "$OUT"
