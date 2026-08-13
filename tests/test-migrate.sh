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
# 2400 paragraphs -> >10 chunks, so the "(part 10/NN)" suffix is wider than a
# single-digit estimate would reserve.
{ printf -- '---\nname: big\ndescription: big one\n---\n'
  for i in $(seq 1 2400); do printf 'paragraph %s with enough text to add up quickly.\n\n' "$i"; done
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

# --roots has to narrow MCP too, not only CLAUDE.md — the help text and SKILL.md
# describe it as scoping both, and it used to fold in every recorded project regardless.
mkdir -p "$H/elsewhere"
if has "remote-x" "$(run --roots "$H/work")" &&
   ! has "remote-x" "$(run --roots "$H/elsewhere")"; then
  ok "--roots scopes MCP discovery, not just CLAUDE.md"
else bad "--roots does not narrow MCP discovery"; fi
rmdir "$H/elsewhere"

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
if ls "$REPO/.agents/rules/"big-10.md >/dev/null 2>&1; then
  ok "a two-digit part count still respects the cap (checked above)"
else bad "fixture no longer produces 10+ parts, so the wide suffix is untested"; fi

# Workspace rules are dead without a project, so registration must happen.
if python3 -c "
import json,glob,sys
ok=any(json.load(open(f)).get('name')=='$REPO' for f in glob.glob('$H/.gemini/config/projects/*.json'))
sys.exit(0 if ok else 1)"; then
  ok "repo registered as an agy project (else .agents/ never loads)"
else bad "repo not registered"; fi

if [ -L "$REPO/AGENTS.md" ]; then ok "AGENTS.md symlinked to CLAUDE.md"
else bad "no AGENTS.md symlink"; fi

# Registration alone does not activate .agents/ in print mode — agy -p always uses
# cache/default_project_id.txt. The report has to hand over the id to pass to --project,
# or the memory looks migrated and silently never loads.
PID="$(python3 -c "
import json,glob
for f in glob.glob('$H/.gemini/config/projects/*.json'):
    d=json.load(open(f))
    if d.get('name')=='$REPO': print(d['id']); break")"
if [ -n "$PID" ] && has "agy --project $PID" "$OUT"; then
  ok "the report names 'agy --project <id>', not just 'registered'"
else bad "project id not surfaced for the user to select"; fi

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

# --- uninstall must not take shared config down with it ----------------------
# skills.json is shared with agy and the desktop apps, which append to it after a
# migration. Even when we created the file, undo has to remove our entry only.
python3 - "$SKJ" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["entries"].append({"path": "/somewhere/agy/added/later"})
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
run --uninstall --apply >/dev/null 2>&1
if [ -f "$SKJ" ] && python3 -c "
import json,sys
p=[x['path'] for x in json.load(open('$SKJ'))['entries']]
sys.exit(0 if p == ['/somewhere/agy/added/later'] else 1)"; then
  ok "uninstall removes only our skills.json entry, keeping foreign ones"
else bad "uninstall clobbered shared skills.json content"; fi
rm -f "$SKJ"

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

# --- the scan must not descend into either tool's own config tree ------------
# ~/.claude/plugins/marketplaces/ holds cloned third-party catalogues. A real run
# over $HOME imported 40 MCP servers the user had never configured out of one.
mkdir -p "$H/.claude/plugins/marketplaces/official/plugins/vendored"
printf '{"mcpServers":{"vendor-catalog-server":{"serverUrl":"https://vendor.test/mcp"}}}\n' \
  > "$H/.claude/plugins/marketplaces/official/plugins/vendored/.mcp.json"
printf '# vendored\n' > "$H/.claude/plugins/marketplaces/official/plugins/vendored/CLAUDE.md"
# An entry Antigravity can never run: it never sets ${CLAUDE_PLUGIN_ROOT}. It has to
# sit in a RECORDED project — .mcp.json is no longer discovered by walking.
mkdir -p "$H/work/withvar"
printf '{"mcpServers":{"needs-var":{"command":"bun","args":["--cwd","${CLAUDE_PLUGIN_ROOT}"]}}}\n' \
  > "$H/work/withvar/.mcp.json"
python3 - "$H" <<'PY2'
import json, os, sys
h = sys.argv[1]; p = os.path.join(h, ".claude.json")
d = json.load(open(p))
d["projects"][os.path.join(h, "work", "withvar")] = {"hasTrustDialogAccepted": False}
json.dump(d, open(p, "w"))
PY2
OUT="$(run --roots "$H")"
if ! has "vendor-catalog-server" "$OUT"; then
  ok "vendored marketplace .mcp.json is not scanned"
else bad "imported a third-party marketplace MCP server"; fi
if has "needs-var" "$OUT" && has "never sets" "$OUT"; then
  ok "an entry using \${CLAUDE_PLUGIN_ROOT} is reported, not imported"
else bad "unexpanded Claude variable was migrated as-is"; fi
rm -rf "$H/.claude/plugins/marketplaces" "$H/work/withvar"

# --- a shared prefix is not containment --------------------------------------
# ~/.claude-pro is a second Claude Code profile (CLAUDE_CONFIG_DIR), not part of
# ~/.claude; ~/Library-notes is not part of ~/Library. A bare startswith() prunes
# both, and silently — the report never says a root was skipped.
mkdir -p "$H/.claude-pro/proj" "$H/Library-notes/deep"
printf '{"mcpServers":{"sibling-prefix-server":{"command":"echo"}}}\n' > "$H/.claude-pro/proj/.mcp.json"
printf '# notes\n' > "$H/Library-notes/deep/CLAUDE.md"
python3 - "$H" <<'PY2'
import json, os, sys
h = sys.argv[1]; p = os.path.join(h, ".claude.json")
d = json.load(open(p))
d["projects"][os.path.join(h, ".claude-pro", "proj")] = {"hasTrustDialogAccepted": False}
json.dump(d, open(p, "w"))
PY2
# --include-repos so the claudemd unit lists paths instead of only a count.
OUT="$(run --roots "$H" --include-repos)"
if has "sibling-prefix-server" "$OUT"; then
  ok "~/.claude-pro is not pruned by the ~/.claude exclusion"
else bad "a sibling sharing a prefix with an excluded root was pruned"; fi
if has "Library-notes" "$OUT"; then
  ok "~/Library-notes is not pruned by the ~/Library exclusion"
else bad "Library-notes was pruned"; fi
rm -rf "$H/.claude-pro" "$H/Library-notes"

# --- a lossy-encoding collision must not misfile memory ----------------------
# `a_b` and `a/b` both encode to `a-b`. Guessing would write one repo's memory into
# the other's .agents/rules/, so the tool must decline to resolve it.
python3 - "$H" <<'PY2'
import json, os, sys
h = sys.argv[1]
p = os.path.join(h, ".claude.json")
d = json.load(open(p))
for x in (os.path.join(h, "coll_x"), os.path.join(h, "coll", "x")):
    os.makedirs(x, exist_ok=True)
    d["projects"][x] = {"hasTrustDialogAccepted": False}
json.dump(d, open(p, "w"))
enc = os.path.join(h, ".claude", "projects",
                   __import__("re").sub(r"[/_.]", "-", os.path.join(h, "coll_x")), "memory")
os.makedirs(enc, exist_ok=True)
open(os.path.join(enc, "amb.md"), "w").write("---\nname: amb\n---\nbody\n")
PY2
OUT="$(run --roots "$H" --include-repos)"
if has "unresolved" "$OUT" && [ ! -d "$H/coll_x/.agents" ] && [ ! -d "$H/coll/x/.agents" ]; then
  ok "an ambiguous encoded directory is reported, not guessed at"
else bad "ambiguous encoding was resolved by guessing"; fi

# --- orphan memory lands flat, not in a nested rules/ subdirectory -----------
# Only a flat rules/ is verified to load. A rules/<sub>/ would be the same silent
# no-op the rest of this tool exists to avoid, so the prefix goes in the filename.
mkdir -p "$H/.claude/projects/-Users-x-deleted-dir/memory"
printf -- '---\nname: orph\ndescription: o\n---\norphan body\n' \
  > "$H/.claude/projects/-Users-x-deleted-dir/memory/orph.md"
run --roots "$H" --include-repos --include-orphan-memory --apply >/dev/null 2>&1
if ls "$RULES"/orphan-*orph.md >/dev/null 2>&1; then
  ok "orphan memory lands flat in rules/ with a filename prefix"
else bad "orphan memory not flattened into rules/"; fi
if [ -z "$(find "$RULES" -mindepth 1 -type d 2>/dev/null)" ]; then
  ok "no nested subdirectory under rules/"
else bad "created a rules/ subdirectory of unverified behaviour"; fi

# --- a failing step must not report success ----------------------------------
# Reinstall from scratch, then wedge one destination so its write raises. The run
# must exit non-zero and must still have persisted what it did manage to do —
# saving the manifest only at the end would strand those files beyond --uninstall.
run --uninstall --apply >/dev/null 2>&1
rm -rf "$H/.gemini/.agy-migrate"
mkdir -p "$H/.gemini/config/skills.json"        # a directory where a file must go
OUT="$(run --roots "$H" --apply)"; RC=$?
rmdir "$H/.gemini/config/skills.json" 2>/dev/null
if [ "$RC" -eq 17 ]; then ok "a failed step exits exactly 17 (not 1, the usage code)"
else bad "failed step exited $RC, want 17"; fi
if has "failed" "$OUT"; then ok "the failure is named in the output"
else bad "failure not reported"; fi
if [ -f "$H/.gemini/.agy-migrate/manifest.json" ]; then
  ok "manifest persisted despite the failure (uninstall can still clean up)"
else bad "manifest lost on failure"; fi
run --uninstall --apply >/dev/null 2>&1

# --- exit codes conform to the plugin's shared contract ----------------------
NO_COLOR=1 python3 "$MIG" --only pluigns >/dev/null 2>&1
if [ $? -eq 1 ]; then ok "a misspelt --only unit is a usage error, not an empty plan"
else bad "unknown --only unit did not fail"; fi
NO_COLOR=1 python3 "$MIG" --definitely-not-a-flag >/dev/null 2>&1
if [ $? -eq 1 ]; then ok "a bad flag exits 1 (usage error), not argparse's default 2"
else bad "bad flag did not exit 1"; fi
( CLAUDE_CONFIG_DIR="$TMP/nope" NO_COLOR=1 python3 "$MIG" >/dev/null 2>&1 )
if [ $? -eq 18 ]; then ok "a missing prerequisite exits 18, not 1"
else bad "missing prerequisite did not exit 18"; fi

# --- postprocess_staged: the two repairs the importer makes necessary ---------
# The plugins unit needs a real agy, but the glue that repairs its output does not:
# hand-build the exact tree the importer produces and drive the function directly.
# This is the code that actually decides whether a migrated plugin works.
if python3 - "$MIG" "$TMP" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tmp = sys.argv[2]

src = os.path.join(tmp, "src", "p")                       # the Claude-side original
staged = os.path.join(tmp, "stage", ".gemini", "config", "plugins", "p")
for d in (src, os.path.join(staged, ".claude-plugin"), os.path.join(staged, "commands"),
          os.path.join(staged, "hooks"), os.path.join(staged, "skills", "p-cmd-x")):
    os.makedirs(d, exist_ok=True)

# Original plugin: one remote server, one stdio server.
json.dump({"mcpServers": {"rem": {"type": "http", "url": "https://ex.test/mcp"},
                          "loc": {"command": "echo", "args": ["1"]}}},
          open(os.path.join(src, ".mcp.json"), "w"))

# Exactly what the importer emits: the remote entry gutted to an empty command.
json.dump({"mcpServers": {"rem": {"command": "", "args": None, "cwd": "", "env": None},
                          "loc": {"command": "echo", "args": ["1"], "cwd": "", "env": None}}},
          open(os.path.join(staged, "mcp_config.json"), "w"))
# ...Claude's hook schema copied verbatim, pointing at a script in hooks/.
json.dump({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
    {"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/run.sh"}]}]}},
          open(os.path.join(staged, "hooks.json"), "w"))
json.dump({"hooks": {}}, open(os.path.join(staged, "hooks", "hooks.json"), "w"))
open(os.path.join(staged, "hooks", "run.sh"), "w").write("#!/bin/sh\n")
open(os.path.join(staged, "commands", "x.md"), "w").write("---\ndescription: c\n---\nbody\n")
open(os.path.join(staged, "skills", "p-cmd-x", "SKILL.md"), "w").write(
    "---\ndescription: c\n---\nbody\n")           # command-derived: no name:
json.dump({"name": "p"}, open(os.path.join(staged, ".claude-plugin", "plugin.json"), "w"))

notes = m.postprocess_staged(os.path.join(tmp, "stage"), {"p": src}, m.Plan())

mcp = json.load(open(os.path.join(staged, "mcp_config.json")))["mcpServers"]
assert mcp["rem"] == {"serverUrl": "https://ex.test/mcp"}, mcp   # URL recovered
assert mcp["loc"]["command"] == "echo" and "cwd" not in mcp["loc"], mcp  # blanks dropped

h = json.load(open(os.path.join(staged, "hooks.json")))
assert list(h) == ["p-hooks"], h                                  # named-hook map
assert h["p-hooks"]["PreToolUse"][0]["matcher"] == "run_command", h
cmd = h["p-hooks"]["PreToolUse"][0]["hooks"][0]["command"]
assert "CLAUDE_PLUGIN_ROOT" not in cmd and cmd.startswith("./"), cmd

# hooks/ holds the executable the rewritten command points at — it must survive,
# while the Claude-side inputs the importer already consumed must not.
assert os.path.isfile(os.path.join(staged, "hooks", "run.sh"))
assert not os.path.exists(os.path.join(staged, "hooks", "hooks.json"))
for junk in (".claude-plugin", "commands", ".mcp.json"):
    assert not os.path.exists(os.path.join(staged, junk)), junk

fm = open(os.path.join(staged, "skills", "p-cmd-x", "SKILL.md")).read()
assert fm.startswith("---\nname: p-cmd-x\n"), fm                  # name: restored
assert any("restored remote MCP" in n for n in notes), notes
PY
then ok "postprocess_staged repairs MCP + hooks and keeps the hook scripts"
else bad "postprocess_staged integration check failed"; fi

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
