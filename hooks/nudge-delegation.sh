#!/usr/bin/env bash
#
# UserPromptSubmit hook: a cheap, deterministic nudge toward delegation when the
# user's prompt LOOKS like bulk work above the delegation break-even.
#
# Design principle: this supplies judgment MATERIAL — the DECISION stays with
# Claude (per the skill's cost discipline). It never forces a delegation and it
# never fires the wrapper itself: full automation is a measured net loss below
# the break-even, so the break-even call must remain a per-task judgment.
#
# Heuristic is deliberately conservative (volume/fan-out phrases, EN + JA), and
# the nudge text is a FIXED string — the user's prompt is never echoed back into
# the context (no escaping/injection surface).
#
# Toggle via plugin userConfig `delegation_nudge`
# (env CLAUDE_PLUGIN_OPTION_DELEGATION_NUDGE: off/false/0/no/disabled). Default: on.
#
set -uo pipefail

raw="$(printf '%s' "${CLAUDE_PLUGIN_OPTION_DELEGATION_NUDGE:-on}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$raw" in off|false|0|no|disabled) exit 0 ;; esac

IN="$(cat 2>/dev/null || true)"
[ -n "$IN" ] || exit 0

# Extract ONLY the prompt field (matching on the whole payload would false-positive
# on cwd/paths). python3 is already a plugin dependency (measure-session, agy-trace).
PROMPT="$(printf '%s' "$IN" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("prompt",""))
except Exception: pass' 2>/dev/null || true)"
[ -n "$PROMPT" ] || exit 0

# Already delegating explicitly? Stay quiet.
case "$PROMPT" in *antigravity*|*agy-delegate*|*agy-job*) exit 0 ;; esac

shopt -s nocasematch
HIT=0
case "$PROMPT" in
  *"all files"*|*"every file"*|*"across the codebase"*|*"entire codebase"*|*"whole repo"*| \
  *migrate*|*migration*|*"generate tests"*|*"test coverage"*|*"exhaustive test"*| \
  *scaffold*|*boilerplate*|*"deep research"*|*"web search"*| \
  *一括*|*全ファイル*|*すべてのファイル*|*網羅*|*移行*|*大量*|*横断*|*リポジトリ全体*)
    HIT=1 ;;
esac
shopt -u nocasematch
[ "$HIT" -eq 1 ] || exit 0

# Fixed nudge. Note the explicit "the judgment is yours" — this is material, not a mandate.
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[antigravity plugin] This prompt looks like BULK work (mass edits / migration / exhaustive tests / fan-out search) — possibly above the delegation break-even. CONSIDER routing the bulk part to the antigravity-delegate subagent (or agy-delegate --digest) so it runs on the cheap executor, then verify its digest. THE JUDGMENT IS YOURS: if the task is actually small, self-contained, or judgement-heavy, do it yourself — delegating below the break-even is a measured net loss. Decide silently; don't mention this notice."}}
JSON
exit 0
