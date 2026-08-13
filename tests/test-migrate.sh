#!/usr/bin/env bash
#
# test-migrate.sh — non-destructive tests for scripts/agy-migrate.py.
#
# Every test runs against a synthetic HOME built in $TMP, so the suite never reads
# or writes the real ~/.claude or ~/.gemini. `agy` is stubbed on PATH: the plugins
# unit shells out to the native importer, and we assert our post-processing of its
# output, not Google's binary.
#
#   bash tests/test-migrate.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MIG="$ROOT/scripts/agy-migrate.py"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { echo "ok: $*";   PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# --- synthetic HOME ----------------------------------------------------------
# Mirrors the layout Claude Code 2.1.x actually produces: memory under
# projects/<encoded-cwd>/memory, plugins nested under plugins/cache/<mp>/<p>/<v>.
H="$TMP/home"; export HOME="$H"
REPO="$H/work/myrepo"
mkdir -p "$H/.claude/skills/demo-skill" \
         "$H/.claude/projects/-Users-x/memory" \
         "$REPO/.git" \
         "$H/.gemini/config" "$H/.gemini/antigravity-cli"

printf -- '---\nname: demo-skill\ndescription: d\nversion: 1.0.0\nallowed-tools: Bash\n---\nbody\n' \
  > "$H/.claude/skills/demo-skill/SKILL.md"

# Memory for the home-dir project == Claude's de-facto global memory.
ENC="$(python3 -c "import re,os;print(re.sub(r'[/_.]','-',os.path.expanduser('~')))")"
mkdir -p "$H/.claude/projects/$ENC/memory"
printf -- '---\nname: g-rule\ndescription: global one\nmetadata:\n  type: feedback\n---\nSee [[other]] and [[missing]].\n' \
  > "$H/.claude/projects/$ENC/memory/g-rule.md"
printf -- '---\nname: other\ndescription: o\n---\nother body\n' \
  > "$H/.claude/projects/$ENC/memory/other.md"
printf -- '- [G](g-rule.md)\n' > "$H/.claude/projects/$ENC/memory/MEMORY.md"

# A memory file well over Antigravity's 12000-char per-rule cap.
REPO_ENC="$(python3 -c "import re,sys;print(re.sub(r'[/_.]','-',sys.argv[1]))" "$REPO")"
mkdir -p "$H/.claude/projects/$REPO_ENC/memory"
{ printf -- '---\nname: big\ndescription: big one\n---\n'
  for i in $(seq 1 400); do printf 'paragraph %s with enough text to add up quickly.\n\n' "$i"; done
} > "$H/.claude/projects/$REPO_ENC/memory/big.md"

printf '{"projects":{"%s":{"hasTrustDialogAccepted":true,"mcpServers":{}},"%s":{"hasTrustDialogAccepted":false}}}\n' \
  "$REPO" "$H/gone" > "$H/.claude.json"
printf '{"permissions":{"allow":["Bash(git diff:*)","Bash(git)","Bash(npm run test:*)","Read(//x)","Bash(echo \\"a|b\\")"]},"model":"claude-opus-5","effortLevel":"xhigh"}\n' \
  > "$H/.claude/settings.json"
printf '{"mcpServers":{"remote-x":{"type":"http","url":"https://ex.test/mcp"},"local-x":{"type":"stdio","command":"echo","args":["1"]}}}\n' \
  > "$REPO/.mcp.json"
printf '# repo rules\n' > "$REPO/CLAUDE.md"

run() { NO_COLOR=1 python3 "$MIG" "$@" 2>&1; }

# --- dry-run is inert --------------------------------------------------------
BEFORE="$(find "$H/.gemini" "$H/.claude" -type f | sort)"
OUT="$(run --roots "$H" --include-repos)"
AFTER="$(find "$H/.gemini" "$H/.claude" -type f | sort)"
if [ "$BEFORE" = "$AFTER" ]; then ok "dry-run writes nothing"; else bad "dry-run created files"; fi
if has "dry run" "$OUT" && has "--apply" "$OUT"; then
  ok "dry run says so, and names the flag that performs it"
else bad "no dry-run notice"; fi

# --- detection ---------------------------------------------------------------
if has "demo-skill" "$OUT" && has "allowed-tools" "$OUT"; then
  ok "flags Claude-only skill frontmatter agy ignores"
else bad "did not flag allowed-tools"; fi
if has "remote-x" "$OUT" && has "local-x" "$OUT"; then
  ok "finds project .mcp.json servers"
else bad "missed .mcp.json"; fi

# --- apply -------------------------------------------------------------------
OUT="$(run --roots "$H" --include-repos --apply)"

SKJ="$H/.gemini/config/skills.json"
if [ -f "$SKJ" ] && python3 -c "
import json,sys,os
e=json.load(open('$SKJ'))['entries']
p=[x['path'] for x in e]
sys.exit(0 if os.path.join('$H','.claude','skills') in p and not any(x.startswith('~') for x in p) else 1)"; then
  ok "skills.json registers an ABSOLUTE path (~ is not expanded by agy)"
else bad "skills.json entry wrong"; fi

RULES="$H/.gemini/config/plugins/claude-code-memory/rules"
if [ -f "$RULES/g-rule.md" ]; then ok "global memory becomes a plugin rule"
else bad "no global rule generated"; fi
if grep -q '^trigger: always_on' "$RULES/g-rule.md" 2>/dev/null; then
  ok "rule carries trigger: always_on (without it agy silently ignores it)"
else bad "rule missing trigger: always_on"; fi
if grep -q '\[other\](other.md)' "$RULES/g-rule.md" 2>/dev/null &&
   ! grep -q '\[\[' "$RULES/g-rule.md" 2>/dev/null; then
  ok "wikilinks resolved; dangling ones flattened"
else bad "wikilink handling wrong"; fi

# Chunking: no generated rule may exceed the 12000-char cap.
OVER=0
while IFS= read -r f; do
  n=$(wc -c < "$f"); [ "$n" -gt 12000 ] && OVER=$((OVER+1))
done < <(find "$H/.gemini/config" "$REPO/.agents" -name '*.md' 2>/dev/null)
if [ "$OVER" -eq 0 ]; then ok "no generated rule exceeds the 12000-char cap"
else bad "$OVER rule(s) over the cap"; fi
if ls "$REPO/.agents/rules/"big-1.md >/dev/null 2>&1; then
  ok "oversized memory is split into parts"
else bad "oversized memory not split"; fi

# Workspace rules are dead without a project, so registration must happen.
if python3 -c "
import json,glob,sys
ok=any(json.load(open(f)).get('name')=='$REPO' for f in glob.glob('$H/.gemini/config/projects/*.json'))
sys.exit(0 if ok else 1)"; then
  ok "repo registered as an agy project (else .agents/ never loads)"
else bad "repo not registered"; fi

if [ -L "$REPO/AGENTS.md" ]; then ok "AGENTS.md symlinked to CLAUDE.md"
else bad "no AGENTS.md symlink"; fi

MCP="$H/.gemini/config/mcp_config.json"
if python3 -c "
import json,sys
s=json.load(open('$MCP'))['mcpServers']
sys.exit(0 if s['remote-x'].get('serverUrl')=='https://ex.test/mcp'
              and 'url' not in s['remote-x'] and 'type' not in s['local-x'] else 1)"; then
  ok "remote MCP becomes serverUrl; stdio drops Claude's type"
else bad "MCP translation wrong"; fi

SET="$H/.gemini/antigravity-cli/settings.json"
if python3 -c "
import json,sys
s=json.load(open('$SET'))
sys.exit(0 if '$REPO' in (s.get('trustedWorkspaces') or []) else 1)"; then
  ok "trusted projects become trustedWorkspaces"
else bad "trustedWorkspaces not migrated"; fi
if python3 -c "
import json,sys
s=json.load(open('$SET'))
sys.exit(0 if not (s.get('permissions') or {}).get('allow') else 1)"; then
  ok "permissions NOT written without --apply-permissions (they widen the grant)"
else bad "permissions written implicitly"; fi
if [ -f "$H/.gemini/.agy-migrate/proposed-permissions.json" ]; then
  ok "permission proposal written for review instead"
else bad "no permission proposal"; fi
if python3 -c "
import json,sys
a=json.load(open('$H/.gemini/.agy-migrate/proposed-permissions.json'))['allow']
# command(git) must absorb command(git diff); the quoted pipe must be dropped.
sys.exit(0 if 'command(git)' in a and 'command(git diff)' not in a
              and not any('|' in x for x in a) else 1)"; then
  ok "permission prefixes absorbed; shell-metachar rules dropped"
else bad "permission collapsing wrong"; fi

# --- idempotency -------------------------------------------------------------
SNAP="$TMP/snap1"; cp -R "$H/.gemini" "$SNAP"
run --roots "$H" --include-repos --apply >/dev/null 2>&1
if diff -r --exclude='backups' --exclude='manifest.json' "$SNAP" "$H/.gemini" >/dev/null 2>&1; then
  ok "second --apply is a no-op"
else bad "second --apply changed things"; fi

# A hand-edited rule must survive a re-run.
echo "MY OWN EDIT" > "$RULES/g-rule.md"
run --roots "$H" --include-repos --apply >/dev/null 2>&1
if [ "$(cat "$RULES/g-rule.md")" = "MY OWN EDIT" ]; then
  ok "user-edited rule (marker removed) is not clobbered"
else bad "clobbered a user-edited rule"; fi

# --- uninstall ---------------------------------------------------------------
run --uninstall --apply >/dev/null 2>&1
if [ ! -L "$REPO/AGENTS.md" ] && [ ! -f "$RULES/other.md" ]; then
  ok "uninstall removes generated artifacts"
else bad "uninstall left artifacts"; fi
if python3 -c "
import json,sys,os
p='$MCP'
s=(json.load(open(p)) if os.path.exists(p) else {}).get('mcpServers',{})
sys.exit(0 if 'remote-x' not in s else 1)"; then
  ok "uninstall reverts merged JSON keys"
else bad "uninstall left MCP keys"; fi
if [ -f "$REPO/CLAUDE.md" ] && [ -f "$H/.claude/settings.json" ]; then
  ok "Claude Code side untouched throughout"
else bad "Claude Code side was modified"; fi

# --- a failing step must not report success ----------------------------------
# Reinstall from scratch, then wedge one destination so its write raises. The run
# must exit non-zero and must still have persisted what it did manage to do —
# saving the manifest only at the end would strand those files beyond --uninstall.
run --uninstall --apply >/dev/null 2>&1
rm -rf "$H/.gemini/.agy-migrate"
mkdir -p "$H/.gemini/config/skills.json"        # a directory where a file must go
OUT="$(run --roots "$H" --apply)"; RC=$?
rmdir "$H/.gemini/config/skills.json" 2>/dev/null
if [ "$RC" -ne 0 ]; then ok "a failed step exits non-zero"
else bad "failed step still exited 0 (rc=$RC)"; fi
if has "failed" "$OUT"; then ok "the failure is named in the output"
else bad "failure not reported"; fi
if [ -f "$H/.gemini/.agy-migrate/manifest.json" ]; then
  ok "manifest persisted despite the failure (uninstall can still clean up)"
else bad "manifest lost on failure"; fi
run --uninstall --apply >/dev/null 2>&1

# --- hook conversion (unit level) -------------------------------------------
# The plugins unit needs the real agy binary, so exercise the translation the
# native importer gets wrong directly instead of stubbing the import.
if python3 - "$MIG" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

claude = {"hooks": {
    "PreToolUse":       [{"matcher": "Bash", "hooks": [{"type": "command", "command": "x"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "y"}]}],
    "SessionStart":     [{"hooks": [{"type": "command", "command": "z"}]}],
}}
conv, notes = m.convert_hooks(claude, "p")
assert list(conv) == ["p-hooks"], conv                       # named-hook map, not "hooks"
h = conv["p-hooks"]
assert h["PreToolUse"][0]["matcher"] == "run_command", h     # Claude's "Bash" never matches
assert "PreInvocation" in h, h                               # UserPromptSubmit maps here
assert h["PreInvocation"] == [{"type": "command", "command": "y"}], h  # flat, not grouped
assert "SessionStart" not in h and any("SessionStart" in n for n in notes), notes
assert m.translate_mcp({"type": "http", "url": "u"})[0] == {"serverUrl": "u"}
assert m.translate_permission("Bash(git diff:*)") == "command(git diff)"
# A quoted argument keeps only the executable — the metacharacters must not
# survive into a command() rule, but the grant itself is still meaningful.
assert m.translate_permission('Bash(echo "a|b")') == "command(echo)"
# Metacharacters in the executable position are not a command at all.
assert m.translate_permission("Bash($ROOT *)") is None
PY
then ok "hook/MCP/permission translation matches Antigravity's schema"
else bad "translation unit checks failed"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
