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

# Normalize a model id to lowercase alphanumerics only, so a configured display name
# ("Gemini 3.5 Flash (High)") and an `agy models` entry survive comparison regardless of
# format. agy 1.1.5 switched `agy models` output from display names to slugs
# (`gemini-3.5-flash`), which broke a strict grep and made doctor falsely warn that every
# tier model was missing (they still worked). Both forms normalize to a comparable core.
norm_model() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }
# True if $1 (a configured tier model) matches any line in $MODELS, in either direction
# (a slug is a substring of the display name, or vice versa).
model_present() {
  local want line n; want="$(norm_model "$1")"; [ -n "$want" ] || return 1
  while IFS= read -r line; do
    n="$(norm_model "$line")"; [ -n "$n" ] || continue
    case "$want" in *"$n"*) return 0 ;; esac
    case "$n" in *"$want"*) return 0 ;; esac
  done <<EOF
$MODELS
EOF
  return 1
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

# True when version $1 is strictly older than $2. Pure shell on purpose: `sort -V` is
# not universal, and when it is missing the command substitution comes back EMPTY, the
# comparison quietly fails, and the check it guards never fires — a version gate that
# silently does nothing is worse than none, because it reads as a clean bill of health.
# (macOS's own sort does support -V; BusyBox and minimal images are the risk.)
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

# True on native Windows (Git Bash/MSYS/Cygwin), NOT WSL — where headless agy hangs.
on_windows_native() {
  case "${OSTYPE:-}" in msys*|cygwin*|win32) return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

echo "Antigravity for Claude Code — doctor"

# 1. agy on PATH
if command -v agy >/dev/null 2>&1; then
  # version probe is guarded too: `command -v` already proved agy exists, and on a
  # headless hang even `agy --version` shouldn't be able to freeze doctor (issue #6).
  AGY_VER="$(agy_guard 10 --version 2>/dev/null | head -1 | tr -d '[:space:]')"
  ok "agy found: $(command -v agy)  (${AGY_VER:-version unknown})"

  # `--tier` resolves to `--model`, and agy IGNORED --model/--effort in headless `-p`
  # until 1.1.10 — the flag was applied after model configuration had initialised, so
  # the run silently fell back to the persisted default. Nothing surfaces that: the
  # call succeeds, returns sensible text, and reports usage. So on an older agy the
  # plugin's whole routing story is inert and looks like it is working, which is worth
  # a warning rather than a footnote.
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
      # NOT the issue-37 mechanism. That one was MCP children holding a capture
      # PIPE open, and there is no pipe left to hold — agy's stdout goes to a
      # file now. What can still hang here is agy blocking INTERNALLY while a
      # configured MCP server never finishes connecting, which reproduces even
      # with stdout on a file and looks identical from the outside.
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
    # 2b. configured tier->model names exist (respecting userConfig remaps). agy is
    # multi-model and plan-dependent, so a miss is a WARNING, not a failure.
    FLASH="${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-Gemini 3.5 Flash (High)}"
    FLASH_LO="${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-Gemini 3.5 Flash (Low)}"
    PRO="${CLAUDE_PLUGIN_OPTION_TIER_PRO:-Gemini 3.1 Pro (High)}"
    for m in "$FLASH" "$FLASH_LO" "$PRO"; do
      if model_present "$m"; then
        ok "tier model present: $m"
      else
        warn "tier model not in 'agy models': $m"
        info "agy is multi-model/plan-dependent — remap tiers via CLAUDE_PLUGIN_OPTION_TIER_* (or set _DEFAULT_MODEL), or pass --model <name from \`agy models\`)"
      fi
    done
  elif [ "$AGY_TIMED_OUT" -eq 0 ]; then
    # Empty WITHOUT a timeout kill: genuinely no models -> auth/network is the likely cause.
    bad "agy could not list models (not authenticated, or no network)"
    info "fix: authenticate agy (run \`agy\` once interactively) and check GCP access"
    info "if agy works interactively but is empty here, suspect a headless/no-TTY hang instead (see above)"
  fi
fi

# 3. agy GCP config
SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
if [ -f "$SETTINGS" ]; then
  PROJ="$(sed -n 's/.*"project"[: ]*"\([^"]*\)".*/\1/p' "$SETTINGS" | head -1)"
  LOC="$(sed -n 's/.*"location"[: ]*"\([^"]*\)".*/\1/p' "$SETTINGS" | head -1)"
  ok "agy settings: ${SETTINGS/#$HOME/~}"
  [ -n "$PROJ" ] && info "GCP project: $PROJ   location: ${LOC:-?}"
else
  info "no agy settings.json yet (${SETTINGS/#$HOME/~})"
fi

# 4. plugin scripts executable
for s in agy-delegate.sh agy-cost-compare.sh cloud-debug.sh agy-trace.sh agy-media.sh; do
  if [ -x "$HERE/$s" ]; then ok "$s executable"; else
    bad "$s not executable"; info "fix: chmod +x \"$HERE/$s\""
  fi
done

# 4b. SessionStart hooks executable
for h in check-agy.sh inject-policy.sh validate-delegate-bash.sh nudge-delegation.sh; do
  if [ -x "$ROOT/hooks/$h" ]; then ok "hooks/$h executable"; else
    bad "hooks/$h not executable"; info "fix: chmod +x \"$ROOT/hooks/$h\""
  fi
done

# 4b2. bin/ entrypoints executable (added to the Bash-tool PATH; commands/skills call
#      these bare names — $CLAUDE_PLUGIN_ROOT is not exported to model-run Bash, issue #11)
for b in agy-delegate agy-job agy-cost-compare agy-doctor cloud-debug agy-trace measure-session agy-media; do
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
