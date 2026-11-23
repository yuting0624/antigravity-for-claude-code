#!/usr/bin/env bash
#
# doctor.sh — read-only health check for the "Antigravity for Claude Code" plugin.
# Verifies the agy CLI is installed + authenticated and the plugin is wired up.
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; FAIL=1; }
warn() { printf '  ⚠ %s\n' "$*"; }   # advisory; does NOT fail the check
info() { printf '    %s\n' "$*"; }
FAIL=0

# Claude Code injects userConfig options as CLAUDE_PLUGIN_OPTION_* into HOOKS only,
# never into Bash-tool subshells (#101). Load them from settings.json when unset.
# shellcheck source=lib/plugin-options.sh
. "$HERE/lib/plugin-options.sh"
load_plugin_options

# Portable <mtime>:<size> signature following symlinks (GNU coreutils stat, else BSD stat).
file_stat_sig() {
  [ -e "$1" ] || { printf '0:0'; return 0; }
  stat -L -c '%Y:%s' "$1" 2>/dev/null || stat -L -f '%m:%z' "$1" 2>/dev/null || printf '0:0'
}

# Portable content signature (`<crc>:<bytes>` via POSIX cksum) for small JSON config files
# that agy rewrites atomically on every invocation (`cache/onboarding.json`) without changing
# content, kept identical to scripts/agy-delegate.sh.
file_content_sig() {
  if [ -f "$1" ]; then
    cksum < "$1" 2>/dev/null | awk '{printf "%s:%s", $1, $2}' || printf '0:0'
  else
    printf '0:0'
  fi
}

# Shared warm tier-fallback cache helpers (kept byte-compatible with scripts/agy-delegate.sh).
# Gated on real agy binary size (> 65536 bytes) in auto mode so unit-test stubs (< 10 KB)
# never read or write $HOME/.cache unless AGY_TIER_CACHE=on is explicitly set.
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

tier_cache_put() { # $1 = slot (flash|flash-lo|pro), $2 = fallback model (empty = evict)
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

# Normalize a model id to lowercase alphanumerics only, so a configured display name
# ("Gemini 4 Hydrogen (High)") and an `agy models` entry survive comparison regardless of
# format. agy 1.1.5 switched `agy models` output from display names to slugs
# (`gemini-3.5-flash`), which broke a strict grep and made doctor falsely warn that every
# tier model was missing (they still worked). Both forms normalize to a comparable core.
norm_model() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }
# True if $1 (a configured tier model) matches a model in $MODELS by exact slug or exact
# display name (case-insensitive), never by substring containment (#102).
#
# Substring matching (`*"$want"*`) made "Gemini 4 Argon" pass against "Gemini 4 Argon (High)"
# (#102) and made "Gemini 3.1 Pro (High)" pass against `gemini-3.1-pro-high  Gemini 3.1 Pro`
# (#104) while `agy -p --model` rejected both with exit 14.
#
# `agy models` lines come in two shapes across versions and test stubs:
#   - two columns: `<slug>  <display name>` (current agy 1.2.x-1.5.x; first token is a
#     lowercase slug such as `gemini-4-hydrogen-high` or `auto`, remainder is the
#     display name) -> compare slug-shaped $1 (no spaces/parens) against the slug column,
#     and display-name $1 against the display column.
#   - one column: `<slug>` only (agy 1.1.5 / stub) or `<display name>` only (pre-1.1.5,
#     where the first token is capitalized) -> compare normalized $1 for exact equality
#     against the normalized line.
model_present() {
  local want line first first_lc rest is_slug=1
  want="$(norm_model "$1")"; [ -n "$want" ] || return 1
  case "$1" in *[[:space:]\(\)]*) is_slug=0 ;; esac
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    first="${line%%[[:space:]]*}"
    first_lc="$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')"
    rest="${line#"$first"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    if [ -n "$rest" ] && [ "$first" = "$first_lc" ]; then
      if [ "$is_slug" -eq 1 ]; then
        [ "$want" = "$(norm_model "$first")" ] && return 0
      else
        [ "$want" = "$(norm_model "$rest")" ] && return 0
      fi
    else
      [ "$want" = "$(norm_model "$line")" ] && return 0
    fi
  done <<EOF
$MODELS
EOF
  return 1
}

# Return the first fallback model in $MODELS for an unremapped tier ($1 = flash|flash-lo|pro).
# Order mirrors scripts/agy-delegate.sh so doctor reports and pre-seeds the exact model
# runtime fallback will select.
first_present_fallback() {
  local tier="$1" cand
  local cands=()
  case "$tier" in
    flash)
      cands=("Gemini 3.8 Flash (High)" "Gemini 3.7 Flash (High)" "Gemini 3.6 Flash (High)" "Gemini 3.5 Flash") ;;
    flash-lo)
      cands=("Gemini 3.8 Flash (Low)" "Gemini 3.5 Flash Lite" "Gemini 3.7 Flash (Low)" "Gemini 3.1 Flash Lite") ;;
    pro)
      cands=("Gemini 4 Carbon (High)" "Gemini 4 Argon (High)" "Gemini 3.1 Pro" "Gemini 3.1 Pro (High)" "Gemini 3.1 Pro (Low)" "Gemini 4 Hydrogen (High)" "Gemini 3.8 Flash (High)") ;;
  esac
  for cand in "${cands[@]:-}"; do
    [ -n "$cand" ] || continue
    if model_present "$cand"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# Suggest up to 3 candidate models from $MODELS when a tier model is missing (#102, #104).
# Ranks direct substring matches (either $n contains $want, e.g. "Gemini 4 Argon" ->
# "Gemini 4 Argon (High)", or $want contains the normalized display name, e.g.
# "Gemini 3.1 Pro (High)" -> "Gemini 3.1 Pro") AHEAD of generic family matches (carbon/argon/pro
# or hydrogen/flash) across the entire model list, so earlier family rows never bury a direct match
# that appears later in `agy models`. Specialist orchestrator/coordinator entries are
# skipped on generic family matches.
suggest_models() {
  local want line first first_lc rest disp n nd fam="flash"
  local direct=() family=() picked=() item
  want="$(norm_model "$1")"
  case "$want" in *neon*|*carbon*|*argon*|*pro*|*opus*|*sonnet*) fam="pro" ;; esac
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    first="${line%%[[:space:]]*}"
    first_lc="$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')"
    rest="${line#"$first"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    disp="$line"
    if [ -n "$rest" ] && [ "$first" = "$first_lc" ]; then
      disp="$rest"
    fi
    n="$(norm_model "$line")"
    nd="$(norm_model "$disp")"
    if [ -n "$want" ] && [ -n "$nd" ] && {
         case "$n" in *"$want"*) true ;; *) false ;; esac ||
         case "$want" in *"$nd"*) true ;; *) false ;; esac
       }; then
      direct+=("$disp")
    else
      case "$n" in *orchestrator*|*coordinator*) continue ;; esac
      if [ "$fam" = "pro" ] && case "$n" in *neon*|*carbon*|*argon*|*pro*|*opus*|*sonnet*) true ;; *) false ;; esac; then
        family+=("$disp")
      elif [ "$fam" = "flash" ] && case "$n" in *hydrogen*|*flash*) true ;; *) false ;; esac; then
        family+=("$disp")
      fi
    fi
  done <<EOF
$MODELS
EOF
  for item in "${direct[@]:-}"; do
    [ -n "$item" ] || continue
    picked+=("$item")
    [ "${#picked[@]}" -ge 3 ] && break
  done
  if [ "${#picked[@]}" -lt 3 ]; then
    for item in "${family[@]:-}"; do
      [ -n "$item" ] || continue
      picked+=("$item")
      [ "${#picked[@]}" -ge 3 ] && break
    done
  fi
  local out=""
  for item in "${picked[@]:-}"; do
    [ -n "$item" ] || continue
    out="${out:+$out, }$item"
  done
  [ -n "$out" ] && printf '%s' "$out"
}

# Resolve a usable `timeout` command (GNU coreutils, or macOS Homebrew gtimeout)
# so a headless/no-TTY hang in `agy models` is bounded instead of freezing doctor.
TO_CMD=""
if   command -v timeout  >/dev/null 2>&1; then TO_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then TO_CMD=gtimeout
fi
# Run agy with a wall-clock guard when possible. Returns agy's exit code, or the
# `timeout` kill code (124 SIGTERM / 137 SIGKILL) when it had to kill a hang. The
# caller inspects the RETURN CODE (not a global) because this runs inside a
# command-substitution subshell, where a global assignment would NOT propagate.
agy_guard() { # usage: agy_guard <secs> <agy-args...>
  # Redirect agy's stdout to a file and `cat` it at the end. Callers capture this with
  # $(...), and agy's stdio MCP children inherit whatever stdout they are handed — if
  # that is the capture pipe they can hold it open forever and the substitution never
  # returns, even after `timeout` kills agy (issue #37). `cat` always exits.
  local secs="$1"; shift
  local f rc
  f="$(mktemp "${TMPDIR:-/tmp}/agy-guard.XXXXXX")"
  if [ -n "$TO_CMD" ]; then
    "$TO_CMD" --kill-after=5 "$secs" agy "$@" >"$f" 2>/dev/null; rc=$?
  else
    agy "$@" >"$f" 2>/dev/null; rc=$?
  fi
  cat "$f"; rm -f "$f"
  return $rc
}

# stdio MCP servers are the precondition for the issue-37 hang and are invisible from
# the plugin's side, so surface them: a hang there is a config symptom, not bad auth.
# Prints the count and returns 0 when at least one is configured.
has_stdio_mcp() {
  command -v python3 >/dev/null 2>&1 || return 1
  # TWO sources, per agy's own embedded docs:
  #   "Global Configuration: ~/.gemini/config/mcp_config.json (applies to all ...)"
  #   "Plugin Configuration: plugins/<plugin_name>/mcp_config.json (active ...)"
  # Counting only the global file undercounts, and this is a diagnostic — a miss
  # is silent, so it fails to help exactly the person who needs it.
  local root="${AGY_CONFIG_DIR:-${HOME}/.gemini/config}"
  local files=("$root/mcp_config.json")
  local p
  for p in "$root"/plugins/*/mcp_config.json; do
    [ -r "$p" ] && files+=("$p")
  done
  python3 -c '
import json, sys
n = 0
for path in sys.argv[1:]:
    try:
        servers = (json.load(open(path)) or {}).get("mcpServers") or {}
    except Exception:
        continue
    # A stdio server is launched as a local process, so it carries "command"
    # (verified against agy 1.1.9: remote servers use "serverUrl", not the
    # "url"/"httpUrl" spelling other MCP clients use — do not match on those).
    n += sum(1 for v in servers.values() if isinstance(v, dict) and v.get("command"))
print(n)
sys.exit(0 if n else 1)
' "${files[@]}" 2>/dev/null
}

# Inspect MDM admin_settings.json when present (Linux /etc/antigravity/admin_settings.json,
# macOS /Library/Application Support/Antigravity/admin_settings.json, or AGY_ADMIN_SETTINGS_PATH).
# Emits TAB-separated `<kind>\t<msg>` lines (`info` or `warn`).
inspect_admin_settings() {
  local p="${AGY_ADMIN_SETTINGS_PATH:-}"
  if [ -z "$p" ]; then
    if [ -r "/etc/antigravity/admin_settings.json" ]; then
      p="/etc/antigravity/admin_settings.json"
    elif [ -r "/Library/Application Support/Antigravity/admin_settings.json" ]; then
      p="/Library/Application Support/Antigravity/admin_settings.json"
    fi
  fi
  [ -n "$p" ] && [ -r "$p" ] || return 1
  command -v python3 >/dev/null 2>&1 || { printf 'info\tMDM policy present: %s\n' "$p"; return 0; }
  python3 -c '
import json, re, sys
path = sys.argv[1]
try:
    raw = open(path, encoding="utf-8", errors="replace").read()
    # admin_settings.json permits JSONC line comments in upstream hujson; strip simple // lines
    clean = re.sub(r"(?m)^[ \t]*//.*$", "", raw)
    d = json.loads(clean) or {}
except Exception:
    print("info\tMDM policy present: " + path)
    sys.exit(0)
gw = d.get("gateway") or {}
ac = d.get("agentControls") or {}
pr = d.get("proxy") or {}
parts = []
if isinstance(gw, dict) and gw.get("url"):
    parts.append("gateway=" + str(gw.get("url")))
if isinstance(ac, dict) and ac.get("permissionPreset"):
    parts.append("permissionPreset=" + str(ac.get("permissionPreset")))
suffix = (" (" + ", ".join(parts) + ")") if parts else ""
print("info\tMDM policy active: " + path + suffix)
if isinstance(gw, dict) and gw.get("url") and gw.get("routeWebFetch") is True:
    addr = str((pr.get("address") if isinstance(pr, dict) else "") or "").strip()
    if not addr:
        print("warn\tadmin_settings.json sets gateway.routeWebFetch=true without proxy.address — agy 1.5.8+ disables URL reads (read_url_content) fail-closed")
' "$p" 2>/dev/null
}

# Report `permissions.allow` entries agy cannot use as written. Prints one
# TAB-separated `<class>\t<reason>\t<entry>` line each and returns 0 when any were found.
bad_allow_rules() {   # $1 = the allow rules, one per line
  command -v python3 >/dev/null 2>&1 || return 1
  [ -n "${1:-}" ] || return 1
  python3 -c '
import re, shlex, sys

allow = [l for l in sys.argv[1].split(chr(10)) if l.strip()]

PREFIX = {"time", "!", "{", "}", "[[", "]]", "if", "then", "elif", "else", "fi",
          "case", "esac", "for", "select", "while", "until", "do", "done", "in",
          "function", "coproc"}

PLACEHOLDER = re.compile(r"<[A-Za-z0-9_./\-]+>")
PLACEHOLDER_REASON = "unsubstituted placeholder — replace <...> with a real value"

bad = []
for e in allow:
    if not isinstance(e, str):
        bad.append((repr(e), "not a string", "unparseable")); continue
    t = e.strip()
    if not t:
        bad.append(("(empty string)", "empty entry", "unparseable")); continue
    i = t.find("(")
    if i < 0 or not t.endswith(")"):
        if PLACEHOLDER.fullmatch(t):
            bad.append((t, PLACEHOLDER_REASON, "unparseable"))
        continue
    name, inner = t[:i].strip(), t[i + 1:-1]
    if not inner.strip():
        bad.append((t, "empty rule body",
                    "zerowords" if name in ("", "command") else "unparseable")); continue
    if name != "command":
        if PLACEHOLDER.search(inner):
            bad.append((t, PLACEHOLDER_REASON, "unparseable"))
        continue
    try:
        words = shlex.split(inner, comments=True)
    except ValueError:
        continue
    while words and words[0] in PREFIX:
        words.pop(0)
    if not words:
        bad.append((t, "tokenizes to zero command words", "zerowords"))

def esc(x):
    return (x.replace(chr(92), chr(92) * 2).replace(chr(9), chr(92) + "t")
             .replace(chr(10), chr(92) + "n").replace(chr(13), chr(92) + "r"))

for t, why, cls in bad:
    print("%s\t%s\t%s" % (cls, why, esc(t)))
sys.exit(0 if bad else 1)
' "$1" 2>/dev/null
}

# True when version $1 is strictly older than $2. Pure shell on purpose: `sort -V` is
# not universal.
ver_lt() {
  local a="$1" b="$2" i x y
  for i in 1 2 3; do
    x="$(printf '%s' "$a" | cut -d. -f"$i")"; y="$(printf '%s' "$b" | cut -d. -f"$i")"
    case "$x" in ''|*[!0-9]*) x=0 ;; esac
    case "$y" in ''|*[!0-9]*) y=0 ;; esac
    [ "$x" -lt "$y" ] && return 0
    [ "$x" -gt "$y" ] && return 1
  done
  return 1                            # equal is not older
}

# The allow rules agy will actually apply, one per line.
allow_rules() {
  case "${AGY_VER:-}" in
    ''|*[!0-9.]*) : ;;
    *)
      if ! ver_lt "$AGY_VER" 1.1.12; then
        local resolved
        resolved="$(agy_guard 20 -p /permissions 2>/dev/null)"
        if [ -n "$resolved" ]; then
          printf '%s\n' "$resolved" | awk -F'\t' '$2 == "allow" && $3 != "" { print $3 }'
          return 0
        fi
      fi ;;
  esac
  [ -f "$SETTINGS" ] || return 1
  python3 -c '
import json, sys
try:
    allow = ((json.load(open(sys.argv[1])) or {}).get("permissions") or {}).get("allow")
except Exception:
    sys.exit(1)
if not isinstance(allow, list):
    sys.exit(1)
for e in allow:
    print(e if isinstance(e, str) else repr(e))
' "$SETTINGS" 2>/dev/null
}

# True on native Windows (Git Bash/MSYS/Cygwin), NOT WSL — where headless agy hangs.
on_windows_native() {
  case "${OSTYPE:-}" in msys*|cygwin*|win32) return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

# Validate one tier slot ($1 = flash|flash-lo|pro, $2 = model, $3 = explicit remap value).
# Sets LAST_EFFECTIVE_TIER_MODEL to whichever model (primary or fallback) is usable on this plan.
LAST_EFFECTIVE_TIER_MODEL=""
check_tier_slot() {
  local slot="$1" m="$2" explicit="${3:-}" fb=""
  LAST_EFFECTIVE_TIER_MODEL=""
  if model_present "$m"; then
    ok "tier model present: $m"
    tier_cache_put "$slot" ""
    LAST_EFFECTIVE_TIER_MODEL="$m"
  elif [ -z "$explicit" ] && fb="$(first_present_fallback "$slot")" && [ -n "$fb" ]; then
    ok "tier '$slot' fallback model present: $fb ($m not on this plan; auto-fallback active)"
    tier_cache_put "$slot" "$fb"
    LAST_EFFECTIVE_TIER_MODEL="$fb"
  else
    warn "tier model not in 'agy models': $m"
    local sugg
    sugg="$(suggest_models "$m")"
    [ -n "$sugg" ] && info "available in 'agy models': $sugg"
    info "agy is multi-model/plan-dependent — remap tiers via CLAUDE_PLUGIN_OPTION_TIER_* (or set _DEFAULT_MODEL), or pass --model <name from \`agy models\`>"
  fi
}

echo "Antigravity for Claude Code — doctor"

# 1. agy on PATH
if command -v agy >/dev/null 2>&1; then
  AGY_VER="$(agy_guard 10 --version 2>/dev/null | head -1 | tr -d '[:space:]')"
  ok "agy found: $(command -v agy)  (${AGY_VER:-version unknown})"

  case "$AGY_VER" in
    ''|*[!0-9.]*) : ;;               # unparseable (dev build, wrapper, hang) — say nothing
    *)
      if ver_lt "$AGY_VER" 1.1.10; then
        warn "agy $AGY_VER ignores --model/--effort in headless \`-p\` (fixed in 1.1.10)"
        info "so --tier / tier_* remaps do NOT take effect — every delegation silently runs"
        info "your persisted default model instead, and nothing in the output says so."
        info "fix: \`agy update\` to 1.1.10 or newer."
      fi ;;
  esac
else
  bad "agy NOT on PATH"
  info "fix: install the Antigravity CLI, then ensure its bin dir is on PATH"
fi

# 2. agy authenticated (can list models). Guarded by a wall-clock timeout so a
#    headless/no-TTY hang (issue #6, esp. native Windows) doesn't freeze doctor
#    and isn't misreported as "not authenticated".
if command -v agy >/dev/null 2>&1; then
  if [ -z "$TO_CMD" ]; then
    warn "no \`timeout\`/\`gtimeout\` on PATH — cannot bound a possible \`agy models\` hang"
    info "install coreutils \`timeout\` (or Homebrew \`gtimeout\`) so doctor can tell a hang from an auth failure"
  fi
  MODELS="$(agy_guard 20 models 2>/dev/null)"; AGY_RC=$?
  AGY_TIMED_OUT=0
  { [ "$AGY_RC" -eq 124 ] || [ "$AGY_RC" -eq 137 ]; } && AGY_TIMED_OUT=1
  if [ "$AGY_TIMED_OUT" -eq 1 ]; then
    bad "\`agy models\` hung and was killed after 20s — this is NOT an auth problem"
    if MCP_N="$(has_stdio_mcp)"; then
      info "you have $MCP_N stdio MCP server(s) configured (~/.gemini/config/mcp_config.json and plugins/*/mcp_config.json)."
      info "agy waits on its MCP servers at startup, so one that never finishes connecting blocks \`agy models\` itself."
      info "check the agy log for a server that never reports ready, or disable them temporarily to confirm the cause."
    fi
    info "agy hangs when run headless with no TTY/console (0-byte log, no output)."
    if on_windows_native; then
      info "native Windows: agy needs a real console (ConPTY). Run delegation from WSL/macOS/Linux."
    else
      info "check whether agy is being invoked without a console; prefer WSL/macOS/Linux for headless delegation."
    fi
    info "(your credentials are likely fine — don't re-authenticate based on this.)"
    MODELS=""
  fi
  if [ -n "$MODELS" ]; then
    ok "agy authenticated — $(printf '%s' "$MODELS" | grep -c . ) models available"
    # 2b. configured tier->model names exist (respecting userConfig remaps and automatic
    # plan fallbacks; pinned against agy-delegate.sh in tests/run-tests.sh).
    FLASH="${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-Gemini 4 Hydrogen (High)}"
    FLASH_LO="${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-Gemini 4 Hydrogen (Low)}"
    PRO="${CLAUDE_PLUGIN_OPTION_TIER_PRO:-Gemini 4 Neon (High)}"
    check_tier_slot "flash"    "$FLASH"    "${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-}"
    PROBE_M="${LAST_EFFECTIVE_TIER_MODEL:-$FLASH}"
    check_tier_slot "flash-lo" "$FLASH_LO" "${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-}"
    check_tier_slot "pro"      "$PRO"      "${CLAUDE_PLUGIN_OPTION_TIER_PRO:-}"

    # 2c. Does --model actually TAKE EFFECT?
    # Reply is `<slug>\t<display name>` (or one column on custom stubs). Check both
    # col 1 and col 2 (`cut -s -f2` guarded by `[ -n "$EFF_DISP_N" ]` so single-column
    # output never vacuous-matches `*"$EFF_DISP_N"*`).
    case "${AGY_VER:-}" in
      ''|*[!0-9.]*) : ;;
      *)
        if ! ver_lt "$AGY_VER" 1.1.11; then
          RAW_EFF="$(agy_guard 20 --model "$PROBE_M" -p /model 2>/dev/null | head -1)"
          EFF="$(printf '%s\n' "$RAW_EFF" | cut -f1)"
          EFF_DISP="$(printf '%s\n' "$RAW_EFF" | cut -s -f2)"
          EFF_N="$(norm_model "$EFF")"
          EFF_DISP_N="$(norm_model "$EFF_DISP")"
          WANT_N="$(norm_model "$PROBE_M")"
          if [ -z "$EFF_N" ]; then
            :
          elif case "$WANT_N" in *"$EFF_N"*) true ;; *) case "$EFF_N" in *"$WANT_N"*) true ;; *) false ;; esac ;; esac ||
               { [ -n "$EFF_DISP_N" ] && { case "$WANT_N" in *"$EFF_DISP_N"*) true ;; *) case "$EFF_DISP_N" in *"$WANT_N"*) true ;; *) false ;; esac ;; esac; }; }; then
            ok "--model takes effect (asked for '$PROBE_M', agy reports '$EFF')"
          else
            warn "--model does NOT take effect: asked for '$PROBE_M', agy reports '$EFF'"
            info "every delegation runs '$EFF' instead, and nothing in the output says so."
            info "--tier / tier_* remaps are therefore inert. Check for a persisted default"
            info "or a profile overriding it, then re-run doctor."
          fi
        fi ;;
    esac
  elif [ "$AGY_TIMED_OUT" -eq 0 ]; then
    # Empty WITHOUT a timeout kill: genuinely no models -> auth/network is the likely cause.
    bad "agy could not list models (not authenticated, or no network)"
    info "fix: authenticate agy (run \`agy\` interactively, or \`agy acp --login\` over SSH/headless) and check GCP access"
    info "if agy works interactively but is empty here, suspect a headless/no-TTY hang instead (see above)"
  fi
fi

# 3. agy GCP & auth-route config
SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
if [ -f "$SETTINGS" ]; then
  PROJ="$(sed -n 's/.*"project"[: ]*"\([^"]*\)".*/\1/p' "$SETTINGS" | head -1)"
  LOC="$(sed -n 's/.*"location"[: ]*"\([^"]*\)".*/\1/p' "$SETTINGS" | head -1)"
  MPROV="$(sed -n 's/.*"modelProvider"[: ]*"\([^"]*\)".*/\1/p' "$SETTINGS" | head -1)"
  ok "agy settings: ${SETTINGS/#$HOME/~}"
  [ -n "$PROJ" ] && info "GCP project: $PROJ   location: ${LOC:-?}"
  if [ "$MPROV" = "gemini" ]; then
    if [ -n "${GEMINI_API_KEY:-}" ]; then
      info "auth route: Gemini API key (modelProvider=gemini, GEMINI_API_KEY set)"
    else
      warn "settings.json sets modelProvider=\"gemini\", but GEMINI_API_KEY is not set in this environment"
      info "fix: export GEMINI_API_KEY=... (agy exits non-zero without it when modelProvider is gemini)"
    fi
  fi
else
  info "no agy settings.json yet (${SETTINGS/#$HOME/~})"
fi
case "$(printf '%s' "${AGY_ADC_AUTH:-}" | tr '[:upper:]' '[:lower:]')" in
  true|1|yes) info "auth route: Vertex AI Application Default Credentials (AGY_ADC_AUTH=${AGY_ADC_AUTH})" ;;
esac
[ -n "${AGY_GATEWAY_URL:-}" ] && info "auth route: Enterprise LLM Gateway (AGY_GATEWAY_URL=${AGY_GATEWAY_URL})"
if MDM_OUT="$(inspect_admin_settings)"; then
  while IFS=$'\t' read -r mkind mmsg; do
    [ -n "$mmsg" ] || continue
    if [ "$mkind" = "warn" ]; then warn "$mmsg"; else info "$mmsg"; fi
  done <<EOF
$MDM_OUT
EOF
fi

# 3b. permissions.allow entries agy cannot use as written.
ALLOW_RULES="$(allow_rules)"
if BAD_RULES="$(bad_allow_rules "$ALLOW_RULES")"; then
  warn "permissions.allow: $(printf '%s\n' "$BAD_RULES" | grep -c .) entry/entries agy cannot use as written"
  ZEROWORDS=0
  while IFS="$(printf '\t')" read -r cls why rule; do
    [ -n "$rule" ] || continue
    info "$rule — $why"
    [ "$cls" = zerowords ] && ZEROWORDS=1
  done <<EOF
$BAD_RULES
EOF
  info "an entry agy cannot use grants nothing, so the tool it was meant to cover is"
  info "still denied (exit 15) with nothing in the message naming the rule."
  if [ "$ZEROWORDS" -eq 1 ]; then
    case "${AGY_VER:-}" in
      ''|*[!0-9.]*)
        info "a rule naming no command is also version-sensitive: before agy 1.1.11 it"
        info "matched EVERY command. Check your version." ;;
      *)
        if ver_lt "$AGY_VER" 1.1.11; then
          info "worse on agy $AGY_VER: a rule naming no command matches EVERY command there"
          info "and silently auto-approves anything the agent runs — broader than the --yolo"
          info "it was chosen instead of. Fix the entry, or \`agy update\` to 1.1.11+."
        fi ;;
    esac
  fi
fi

# 4. plugin scripts executable
for s in agy-delegate.sh agy-handoff.sh agy-job.sh agy-cost-compare.sh cloud-debug.sh agy-trace.sh agy-media.sh agy-migrate.py; do
  if [ -x "$HERE/$s" ]; then ok "$s executable"; else
    bad "$s not executable"; info "fix: chmod +x \"$HERE/$s\""
  fi
done

# 4b. SessionStart / PreToolUse / UserPromptSubmit hooks executable
for h in check-agy.sh inject-policy.sh validate-delegate-bash.sh nudge-delegation.sh; do
  if [ -x "$ROOT/hooks/$h" ]; then ok "hooks/$h executable"; else
    bad "hooks/$h not executable"; info "fix: chmod +x \"$ROOT/hooks/$h\""
  fi
done

# 4b2. bin/ entrypoints executable (added to the Bash-tool PATH; commands/skills call
#      these bare names — $CLAUDE_PLUGIN_ROOT is not exported to model-run Bash, issue #11)
for b in agy-delegate agy-handoff agy-job agy-cost-compare agy-doctor cloud-debug agy-trace measure-session agy-media agy-migrate; do
  if [ -x "$ROOT/bin/$b" ]; then ok "bin/$b executable"; else
    bad "bin/$b not executable"; info "fix: chmod +x \"$ROOT/bin/$b\""
  fi
done

# 4c. WSL: agy --add-dir over a Windows mount (/mnt/*) reads via a slow 9p bridge
if grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
  case "$PWD" in
    /mnt/*)
      warn "WSL + workspace on a Windows mount ($PWD)"
      info "agy --add-dir reads this over a slow 9p bridge (the 'agy is slow' trap — calls can take 20s+)."
      info "fix: move the repo into the WSL Linux filesystem (e.g. ~/projects) for ~10x faster I/O" ;;
    *) ok "WSL detected; workspace is on the Linux filesystem" ;;
  esac
fi

# 5. plugin version
PJ="$ROOT/.claude-plugin/plugin.json"
[ -f "$PJ" ] && ok "plugin: $(sed -n 's/.*"version"[: ]*"\([^"]*\)".*/v\1/p' "$PJ" | head -1)"

echo ""
if [ "$FAIL" -eq 0 ]; then echo "All checks passed — ready to delegate."; else
  echo "Some checks failed — see fixes above."; fi
exit "$FAIL"
