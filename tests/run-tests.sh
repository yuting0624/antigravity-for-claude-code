#!/usr/bin/env bash
#
# run-tests.sh — dependency-free tests for the plugin (bash, python3, node).
# The delegation server has its own suite in its repository (scripts/verify.sh);
# this file checks what the PLUGIN promises: manifests, hooks, commands, the
# shipped bundle, and the Conductor-side scripts.
#
#   bash tests/run-tests.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOKS="$ROOT/hooks"
MEASURE="$ROOT/scripts/measure-session.py"
SERVER="$ROOT/server/index.js"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0

check() { # desc  expected_rc  actual_rc  [substr]  [actual_out]
  local desc="$1" erc="$2" arc="$3" sub="${4:-}" out="${5:-}"
  if [ "$arc" != "$erc" ]; then echo "FAIL: $desc (rc want $erc got $arc)"; FAIL=$((FAIL+1)); return; fi
  if [ -n "$sub" ] && ! grep -qF -- "$sub" <<<"$out"; then
    echo "FAIL: $desc (missing '$sub' in output)"; FAIL=$((FAIL+1)); return; fi
  echo "ok: $desc"; PASS=$((PASS+1))
}
absent() { # desc  needle  haystack
  if grep -qF -- "$2" <<<"$3"; then echo "FAIL: $1 (found '$2')"; FAIL=$((FAIL+1)); else echo "ok: $1"; PASS=$((PASS+1)); fi
}

# bash does not hoist function definitions; a helper called above its definition is
# exit 127 and every `if` around it silently takes the else branch.
if ! python3 "$HERE/check-helper-order.py" "$0"; then
  echo "FAIL: helper defined below its first use in $0"; FAIL=$((FAIL+1))
else echo "ok: helpers are defined before use"; PASS=$((PASS+1)); fi

echo "== plugin contract =="
python3 - "$ROOT" <<'PY'
import glob, json, os, re, sys
root = sys.argv[1]
errs = []
def need(c, m):
    if not c: errs.append(m)
def p(*a): return os.path.join(root, *a)

pj = json.load(open(p(".claude-plugin", "plugin.json")))
need(pj.get("name") == "antigravity", "plugin name")
need(re.match(r"^\d+\.\d+\.\d+$", pj.get("version", "")), "plugin version is semver")
need(pj["version"].split(".")[0] >= "1", "1.0 line")
srv = pj.get("mcpServers", {}).get("delegation")
need(bool(srv), "plugin.json declares the delegation MCP server")
if srv:
    need(srv.get("command") == "node", "server command is node")
    need(any("${CLAUDE_PLUGIN_ROOT}/server/index.js" in a for a in srv.get("args", [])), "server args point at ${CLAUDE_PLUGIN_ROOT}/server/index.js")
    need("env" not in srv or all(not v.startswith("${user_config") for v in srv["env"].values()), "no ${user_config} in server env (known to break spawning)")
need(os.path.isfile(p("server", "index.js")) and os.path.getsize(p("server", "index.js")) > 1_000_000, "server bundle present and bundled")
need(os.path.isfile(p("server", "prices.json")), "server/prices.json shipped beside the bundle")
ver = open(p("server", "VERSION")).read().strip() if os.path.isfile(p("server", "VERSION")) else ""
need(ver and ver == pj.get("serverVersion"), f"server/VERSION ({ver}) matches plugin.json serverVersion ({pj.get('serverVersion')})")

hooks = json.load(open(p("hooks", "hooks.json")))
cmds = []
for ev, entries in hooks.get("hooks", {}).items():
    for e in entries:
        for h in e.get("hooks", []):
            cmds.append(h.get("command", ""))
need(bool(cmds), "hook commands present")
for c in cmds:
    m = re.search(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\"']+)", c)
    need(bool(m), "hook command missing CLAUDE_PLUGIN_ROOT path: " + c)
    if m:
        need(os.path.isfile(p(m.group(1))), "hook references missing file: " + m.group(1))
        need(os.access(p(m.group(1)), os.X_OK), "hook not executable: " + m.group(1))
need(any("log-delegation.sh" in c for c in cmds), "PostToolUse usage-log hook wired")
need(not any("check-agy" in c for c in cmds), "no agy check hook left")
post = hooks["hooks"].get("PostToolUse", [])
need(any("delegation" in (e.get("matcher") or "") for e in post), "PostToolUse matcher targets the delegation server")

for f in glob.glob(p("commands", "*.md")) + [p("skills", "antigravity", "SKILL.md"), p("agents", "antigravity-delegate.md")]:
    t = open(f).read()
    need(t.startswith("---") and t.count("---") >= 2, "no YAML frontmatter: " + os.path.basename(f))
    base = os.path.basename(f)
    if base != "migrate.md":
        need("agy-delegate" not in t and "agy-job" not in t and "--yolo" not in t, "still references the agy transport: " + base)
    need("CLAUDE_PLUGIN_ROOT}/scripts/" not in t and "CLAUDE_PLUGIN_ROOT/scripts/" not in t, "invokes $CLAUDE_PLUGIN_ROOT/scripts (empty on model Bash, issue #11): " + base)

agent = open(p("agents", "antigravity-delegate.md")).read()
fm = agent.split("---")[1]
tools_line = next((l for l in fm.splitlines() if l.startswith("tools:")), "")
tools = [t.strip() for t in tools_line[len("tools:"):].split(",") if t.strip()]
need(bool(tools), "agent declares tools")
for t in tools:
    need(t == "Glob" or t.startswith("mcp__plugin_antigravity_delegation__"), "agent tool is not the delegation server's: " + t)
for banned in ("Bash", "Read", "Write", "Edit"):
    need(banned not in tools, "agent must not have " + banned)
need("hooks:" not in fm, "agent has no PreToolUse gate (it has no Bash to gate)")
need(os.path.isfile(p("hooks", "validate-delegate-bash.sh")), "legacy gate file left untouched on disk")

for b in ("delegation-cli", "delegation-doctor", "cloud-debug", "measure-session", "agy-condense", "agy-tier", "agy-migrate"):
    need(os.access(p("bin", b), os.X_OK), "bin entrypoint missing/not executable: bin/" + b)
for b in ("agy-delegate", "agy-job", "agy-doctor", "agy-trace", "agy-media", "agy-cost-compare"):
    need(not os.path.exists(p("bin", b)), "retired bin entrypoint still present: bin/" + b)
for s in ("scripts/agy-delegate.sh", "scripts/agy-job.sh", "scripts/doctor.sh", "hooks/check-agy.sh"):
    need(not os.path.exists(p(s)), "retired file still present: " + s)

def _ctx_strings(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "additionalContext" and isinstance(v, str): yield v
            else: yield from _ctx_strings(v)
    elif isinstance(o, list):
        for x in o: yield from _ctx_strings(x)
for hf in glob.glob(p("hooks", "*.json")):
    for ac in _ctx_strings(json.load(open(hf))):
        need("CLAUDE_PLUGIN_ROOT" not in ac, "injected additionalContext references $CLAUDE_PLUGIN_ROOT (issue #15): " + os.path.basename(hf))
policy = open(p("hooks", "policy-context.json")).read()
need("COST-AWARE" in policy and "digest_codebase" in policy and "3 or more files" in policy and "never WRITES" in policy, "policy text carries the 1.0 rules")

skill = open(p("skills", "antigravity", "SKILL.md")).read()
need("version: " + pj["version"] in skill, "SKILL.md version matches plugin.json")
for tool in ("digest_codebase", "delegate_task", "review_diff", "job_status", "refs_valid_ratio", "egress"):
    need(tool in skill, "SKILL.md mentions " + tool)

cl = open(p("CHANGELOG.md")).read()
need("## " + pj["version"] in cl, "CHANGELOG has a section for " + pj["version"])
need(os.path.isfile(p("docs", "MIGRATION-1.0.md")), "docs/MIGRATION-1.0.md exists")
if errs:
    print("CONTRACT FAIL:")
    for e in errs: print("  -", e)
    sys.exit(1)
PY
check "plugin contract (manifests, bundle, hooks, agent, commands, skill, docs)" 0 "$?"

echo "== hooks =="
python3 -c "import json; json.load(open('$HOOKS/policy-context.json'))" 2>/dev/null; rc=$?
check "policy-context.json is valid JSON" 0 "$rc"
out=$("$HOOKS/inject-policy.sh" 2>/dev/null); rc=$?
check "inject-policy default on -> emits additionalContext" 0 "$rc" "additionalContext" "$out"
check "inject-policy is cost-aware (not 'delegate everything')" 0 "$rc" "COST-AWARE" "$out"
out=$(CLAUDE_PLUGIN_OPTION_CODING_POLICY=off "$HOOKS/inject-policy.sh" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then echo "ok: inject-policy off -> exit 0 + no output"; PASS=$((PASS+1));
else echo "FAIL: inject-policy off (rc=$rc)"; FAIL=$((FAIL+1)); fi

# A PATH with bash but without node: the shebang still needs `env bash` to resolve.
mkdir -p "$TMP/nonode" && ln -sf "$(command -v bash)" "$TMP/nonode/bash" && ln -sf "$(command -v env)" "$TMP/nonode/env"
out=$(PATH="$TMP/nonode" "$HOOKS/check-server.sh" 2>&1); rc=$?
check "check-server never fails the session (no node on PATH)" 0 "$rc" "node is not on PATH" "$out"
out=$("$HOOKS/check-server.sh" 2>&1); rc=$?
check "check-server quiet when node + bundle are present" 0 "$rc"
if [ -z "$out" ]; then echo "ok: check-server prints nothing when healthy"; PASS=$((PASS+1)); else echo "FAIL: check-server noisy: $out"; FAIL=$((FAIL+1)); fi

NUDGE="$HOOKS/nudge-delegation.sh"
out=$(printf '%s' '{"prompt":"migrate every caller from APIv1 to APIv2 across the codebase"}' | "$NUDGE" 2>/dev/null); rc=$?
check "nudge fires on bulk EN prompt" 0 "$rc" "additionalContext" "$out"
check "nudge preserves Claude's judgment (not a mandate)" 0 "$rc" "THE JUDGMENT IS YOURS" "$out"
check "nudge points at the delegation server" 0 "$rc" "digest_codebase" "$out"
absent "nudge does not mention the retired transport" "agy-delegate" "$out"
printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['hookSpecificOutput']['hookEventName']=='UserPromptSubmit'" 2>/dev/null; rc=$?
check "nudge emits valid UserPromptSubmit JSON" 0 "$rc"
out=$(printf '%s' '{"prompt":"リポジトリ全体のテストを網羅的に生成して"}' | "$NUDGE" 2>/dev/null); rc=$?
check "nudge fires on bulk JA prompt" 0 "$rc" "additionalContext" "$out"
out=$(printf '%s' '{"prompt":"fix the typo in README"}' | "$NUDGE" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then echo "ok: nudge silent on a small prompt"; PASS=$((PASS+1));
else echo "FAIL: nudge fired on a small prompt (rc=$rc)"; FAIL=$((FAIL+1)); fi
out=$(printf '%s' '{"prompt":"use digest_codebase on src and tell me the auth flow"}' | "$NUDGE" 2>/dev/null)
if [ -z "$out" ]; then echo "ok: nudge silent when already delegating"; PASS=$((PASS+1));
else echo "FAIL: nudge fired on an explicit delegation"; FAIL=$((FAIL+1)); fi
out=$(printf '%s' '{"prompt":"migrate all files"}' | CLAUDE_PLUGIN_OPTION_DELEGATION_NUDGE=off "$NUDGE" 2>/dev/null)
if [ -z "$out" ]; then echo "ok: delegation_nudge=off suppresses the nudge"; PASS=$((PASS+1));
else echo "FAIL: nudge fired while disabled"; FAIL=$((FAIL+1)); fi

echo "== log-delegation (PostToolUse usage join) =="
LOG="$TMP/usage.jsonl"
RESP='{"content":[{"type":"text","text":"## Digest\n\nx\n\n```json\n{\"kind\":\"digest_codebase\",\"v\":1,\"stats\":{\"files\":6,\"est_input_tokens\":7782,\"chunks\":1,\"refs_valid_ratio\":1,\"truncated\":false},\"usage\":{\"input_tokens\":10375,\"output_tokens\":508,\"model\":\"gemini-3.6-flash\",\"alias\":\"ingest\",\"driver\":\"vertex\",\"endpoint_class\":\"geap\",\"endpoint_host\":\"aiplatform.googleapis.com\",\"latency_ms\":5203,\"estimated_cost_usd\":0.019,\"session_id\":\"srv-1\",\"request_id\":\"r1\"},\"error\":null}\n```\n\n---\nusage: { input_tokens=10375 }"}],"isError":false}'
printf '{"session_id":"claude-abc","hook_event_name":"PostToolUse","tool_name":"mcp__plugin_antigravity_delegation__digest_codebase","tool_input":{},"tool_response":%s}' "$RESP" \
  | CLAUDE_PLUGIN_OPTION_USAGE_LOG="$LOG" "$HOOKS/log-delegation.sh"; rc=$?
check "log hook exits 0" 0 "$rc"
python3 - "$LOG" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(lines) == 1, lines
e = lines[0]
assert e["claude_session_id"] == "claude-abc" and e["server_session_id"] == "srv-1", e
assert e["tool"] == "digest_codebase" and e["input_tokens"] == 10375 and e["endpoint_class"] == "geap", e
assert e["stats_refs_valid_ratio"] == 1 and e["alias"] == "ingest", e
print("ok")
PY
check "log hook joins Claude session id with server usage (counts only)" 0 "$?"
grep -q "## Digest" "$LOG" && { echo "FAIL: log hook stored digest text"; FAIL=$((FAIL+1)); } || { echo "ok: log hook stores no content"; PASS=$((PASS+1)); }
# printf '%s' — a JSON payload with escaped quotes must not pass through printf's format parser.
printf '%s' '{"session_id":"claude-abc","tool_name":"mcp__plugin_antigravity_delegation__digest_codebase","tool_response":{"content":[{"type":"text","text":"⚠️ Sending to x is not permitted\n\n---\nerror: {\"host\":\"x\",\"code\":15,\"kind\":\"PERMISSION\",\"retry\":false}"}],"isError":true}}' \
  | CLAUDE_PLUGIN_OPTION_USAGE_LOG="$LOG" "$HOOKS/log-delegation.sh"
python3 -c "import json,sys; ls=[json.loads(l) for l in open('$LOG')]; e=ls[-1]; assert e['error_code']==15 and e['error_kind']=='PERMISSION' and e['endpoint_host']=='x', e" 2>/dev/null
check "log hook records failures with the taxonomy code" 0 "$?"
printf '%s' '{"session_id":"s","tool_name":"mcp__plugin_antigravity_delegation__job_status","tool_response":{"content":[{"type":"text","text":"No jobs"}]}}' | CLAUDE_PLUGIN_OPTION_USAGE_LOG="$LOG" "$HOOKS/log-delegation.sh"
n=$(grep -c . "$LOG"); check "log hook ignores responses without usage" 0 0 && [ "$n" = 2 ] || { echo "FAIL: unexpected log line count $n"; FAIL=$((FAIL+1)); }

echo "== shipped server (offline) =="
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
out=$(HOME="$FAKE_HOME" GEMINI_MCP_LEDGER=off node "$SERVER" --cli savings_report '{}' 2>/dev/null); rc=$?
check "server --cli savings_report runs offline" 0 "$rc" "Context offload" "$out"
out=$(HOME="$FAKE_HOME" DELEGATION_JOBS_DIR="$TMP/jobs" node "$SERVER" --cli job_status '{}' 2>/dev/null); rc=$?
check "server --cli job_status runs offline" 0 "$rc" "No jobs" "$out"
node "$SERVER" --cli nope '{}' >/dev/null 2>&1; rc=$?
check "server --cli unknown tool -> exit 1" 1 "$rc"
out=$("$ROOT/bin/delegation-cli" savings_report '{}' 2>/dev/null); rc=$?
check "bin/delegation-cli forwards to the bundle" 0 "$rc" "Context offload" "$out"
# macOS ships no `timeout`; CI installs coreutils' gtimeout. Without either, run unbounded.
if command -v timeout >/dev/null 2>&1; then TO=(timeout 90); elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 90); else TO=(); fi
out=$(HOME="$FAKE_HOME" env -u GOOGLE_APPLICATION_CREDENTIALS CLOUDSDK_CONFIG="$FAKE_HOME/gcloud" GEMINI_MCP_LEDGER=off "${TO[@]}" "$ROOT/bin/delegation-doctor" 2>&1); rc=$?
check "delegation-doctor reports node + bundle version" 0 0 "server bundle" "$out"
grep -q "Egress\|送信先" <<<"$out" && { echo "ok: delegation-doctor shows the egress line"; PASS=$((PASS+1)); } || { echo "FAIL: doctor output lacks egress line"; FAIL=$((FAIL+1)); }

echo "== cloud-debug (dry run) =="
out=$(PATH="$TMP/nogcloud:$PATH" "$ROOT/scripts/cloud-debug.sh" --service demo --print-command 2>&1); rc=$?
check "cloud-debug --print-command shows the delegation step" 0 "$rc" "delegate_task" "$out"
absent "cloud-debug no longer calls the agy wrapper" "agy-delegate" "$out"

echo "== Conductor-side helpers =="
out=$(printf 'fix the typo in the docstring' | "$ROOT/bin/agy-tier" 2>/dev/null); rc=$?
check "agy-tier classifies a trivial prompt" 0 "$rc" "flash" "$out"
out=$(printf 'ERROR: build failed\nnpm ERR! code 1\n' | "$ROOT/bin/agy-condense" --max-chars 400 2>/dev/null); rc=$?
check "agy-condense condenses a log" 0 "$rc" "DIGEST:" "$out"

echo "== measure-session.py =="
SESS="$TMP/claude-abc.jsonl"   # named like the session id the log hook recorded
cat > "$SESS" <<'JSONL'
{"message":{"role":"user","content":"hi"}}
{"message":{"role":"assistant","usage":{"output_tokens":10,"input_tokens":2,"cache_read_input_tokens":100},"content":[{"type":"tool_use","name":"Bash"}]}}
{"message":{"role":"assistant","usage":{"output_tokens":5}}}
JSONL
out=$(python3 "$MEASURE" "$SESS" "T" 2>/dev/null); rc=$?
check "measure: total tokens" 0 "$rc" "TOTAL tokens   117" "$out"
check "measure: cost-weighted" 0 "$rc" "COST-WEIGHTED  87" "$out"
check "measure: turns" 0 "$rc" "turns          2" "$out"
out=$(python3 "$MEASURE" "$SESS" "T" --join "$LOG" 2>/dev/null); rc=$?
check "measure --join prints the delegation side" 0 "$rc" "delegation side" "$out"
check "measure --join counts the joined call" 0 "$rc" "calls          1" "$out"
out=$(python3 "$MEASURE" /no/such/file 2>/dev/null); rc=$?
check "measure: missing file -> exit 1" 1 "$rc"

echo "== linters =="
if python3 "$HERE/check-embedded-python.py" "$ROOT"/scripts/*.sh "$ROOT"/hooks/*.sh; then
  echo "ok: embedded python blocks are intact"; PASS=$((PASS+1))
else echo "FAIL: embedded python block truncated"; FAIL=$((FAIL+1)); fi
for f in "$ROOT"/scripts/*.sh "$ROOT"/hooks/*.sh "$ROOT"/bin/*; do
  bash -n "$f" 2>/dev/null || { echo "FAIL: $f does not parse"; FAIL=$((FAIL+1)); }
done
echo "ok: shell files parse"; PASS=$((PASS+1))

# The migration tool has its own suite (synthetic HOME); it is unrelated to the transport.
if [ -f "$HERE/test-migrate.sh" ]; then
  if bash "$HERE/test-migrate.sh" > "$TMP/migrate.log" 2>&1; then
    echo "ok: agy-migrate suite ($(grep -c '^ok:' "$TMP/migrate.log") checks)"; PASS=$((PASS+1))
  else
    echo "FAIL: agy-migrate suite"; sed 's/^/    /' "$TMP/migrate.log" | tail -20; FAIL=$((FAIL+1))
  fi
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
