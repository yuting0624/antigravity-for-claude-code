#!/usr/bin/env bash
# Pre/PostToolUse hook (Bash, Edit, Write, MultiEdit, NotebookEdit): fingerprint the
# working tree so every change can be attributed to the tool call that made it.
# Appends {"ts","event","tool_name","tool_use_id","head","fp"} to $BENCH_TRACE_LOG.
# Always exits 0; never blocks. Repo root comes from $BENCH_REPO_DIR (set by the harness),
# falling back to the hook's cwd.
set -u
[ -n "${BENCH_TRACE_LOG:-}" ] || exit 0
input="$(cat)"
meta="$(printf '%s' "$input" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("\t\t\t\t"); sys.exit(0)
cmd=str((d.get("tool_input") or {}).get("command","") or "")
head=cmd.strip().split()[0] if cmd.strip() else ""
print("\t".join([str(d.get("hook_event_name","")), str(d.get("tool_name","")), str(d.get("tool_use_id","")), head, str(d.get("cwd",""))]))
' 2>/dev/null)"
ev="${meta%%	*}"; rest="${meta#*	}"
tool="${rest%%	*}"; rest="${rest#*	}"
tuid="${rest%%	*}"; rest="${rest#*	}"
head="${rest%%	*}"; cwd="${rest#*	}"
repo="${BENCH_REPO_DIR:-$cwd}"
fp=""; files="[]"
if [ -n "$repo" ] && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # names + content hashes of modified/untracked files, plus deleted names; the digest is
  # the pairing key, the list (capped) lets the scorer say WHICH files a call changed
  listing="$( { git -C "$repo" ls-files -m -o --exclude-standard -z | (cd "$repo" && xargs -0 shasum -a 1 2>/dev/null); git -C "$repo" ls-files -d | sed 's/^/deleted  /'; } )"
  fp="$(printf '%s' "$listing" | shasum -a 1 | cut -d' ' -f1)"
  files="$(printf '%s' "$listing" | python3 -c '
import json,sys
out=[]
for l in sys.stdin.read().splitlines():
    parts=l.split(None,1)
    if len(parts)==2: out.append([parts[1], parts[0][:12]])
print(json.dumps(out[:200]))' 2>/dev/null || echo "[]")"
fi
ts="$(python3 -c 'import time;print(time.time())' 2>/dev/null || date +%s)"
esc() { printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$1"; }
printf '{"ts":%s,"event":%s,"tool_name":%s,"tool_use_id":%s,"head":%s,"fp":"%s","files":%s}\n' \
  "$ts" "$(esc "$ev")" "$(esc "$tool")" "$(esc "$tuid")" "$(esc "$head")" "$fp" "$files" >>"$BENCH_TRACE_LOG" 2>/dev/null || true
exit 0
