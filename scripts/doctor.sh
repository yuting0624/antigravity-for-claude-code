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

echo "Antigravity for Claude Code — doctor"

# 1. agy on PATH
if command -v agy >/dev/null 2>&1; then
  ok "agy found: $(command -v agy)  ($(agy --version 2>/dev/null | head -1))"
else
  bad "agy NOT on PATH"
  info "fix: install the Antigravity CLI, then ensure its bin dir is on PATH"
fi

# 2. agy authenticated (can list models)
if command -v agy >/dev/null 2>&1; then
  MODELS="$(agy models 2>/dev/null || true)"
  if [ -n "$MODELS" ]; then
    ok "agy authenticated — $(printf '%s' "$MODELS" | grep -c . ) models available"
    # 2b. configured tier->model names exist (respecting userConfig remaps). agy is
    # multi-model and plan-dependent, so a miss is a WARNING, not a failure.
    FLASH="${CLAUDE_PLUGIN_OPTION_TIER_FLASH:-Gemini 3.5 Flash (High)}"
    FLASH_LO="${CLAUDE_PLUGIN_OPTION_TIER_FLASH_LO:-Gemini 3.5 Flash (Low)}"
    PRO="${CLAUDE_PLUGIN_OPTION_TIER_PRO:-Gemini 3.1 Pro (High)}"
    for m in "$FLASH" "$FLASH_LO" "$PRO"; do
      if printf '%s' "$MODELS" | grep -qF "$m"; then
        ok "tier model present: $m"
      else
        warn "tier model not in 'agy models': $m"
        info "agy is multi-model/plan-dependent — remap tiers via CLAUDE_PLUGIN_OPTION_TIER_* (or set _DEFAULT_MODEL), or pass --model <name from \`agy models\`)"
      fi
    done
  else
    bad "agy could not list models (not authenticated, or no network)"
    info "fix: authenticate agy (run \`agy\` once interactively) and check GCP access"
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
for s in agy-delegate.sh agy-cost-compare.sh; do
  if [ -x "$HERE/$s" ]; then ok "$s executable"; else
    bad "$s not executable"; info "fix: chmod +x \"$HERE/$s\""
  fi
done

# 4b. SessionStart hooks executable
for h in check-agy.sh inject-policy.sh validate-delegate-bash.sh; do
  if [ -x "$ROOT/hooks/$h" ]; then ok "hooks/$h executable"; else
    bad "hooks/$h not executable"; info "fix: chmod +x \"$ROOT/hooks/$h\""
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
