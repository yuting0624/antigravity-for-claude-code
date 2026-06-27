#!/usr/bin/env bash
#
# run-tests.sh — dependency-free tests (no bats). Stubs `agy` on PATH and asserts
# agy-delegate.sh behavior + measure-session.py accounting.
#
#   bash tests/run-tests.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DELEGATE="$ROOT/scripts/agy-delegate.sh"
MEASURE="$ROOT/scripts/measure-session.py"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# --- stub `agy` on PATH; behavior controlled by $STUB_MODE -------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
case "${STUB_MODE:-text}" in
  empty)   exit 0 ;;                  # no stdout -> wrapper should exit 3
  fail)    echo "boom" >&2; exit 7 ;; # nonzero  -> wrapper should exit 2
  args)    printf '%s\n' "$*" ;;      # echo args for assertions
  quota)   echo "Error: quota exceeded for this model" >&2; exit 1 ;;     # -> wrapper exit 10
  auth)    echo "Error: request is unauthenticated; please sign in" >&2; exit 1 ;; # -> exit 11
  timeout) echo "Error: deadline exceeded (the request timed out)" >&2; exit 1 ;;  # -> exit 12
  *)       echo "STUB_OK" ;;
esac
STUB
chmod +x "$TMP/bin/agy"
export PATH="$TMP/bin:$PATH"

check() { # desc  expected_rc  actual_rc  [substr]  [actual_out]
  local desc="$1" erc="$2" arc="$3" sub="${4:-}" out="${5:-}"
  if [ "$arc" != "$erc" ]; then echo "FAIL: $desc (rc want $erc got $arc)"; FAIL=$((FAIL+1)); return; fi
  if [ -n "$sub" ] && ! printf '%s' "$out" | grep -qF -- "$sub"; then
    echo "FAIL: $desc (missing '$sub' in output)"; FAIL=$((FAIL+1)); return; fi
  echo "ok: $desc"; PASS=$((PASS+1))
}

echo "== agy-delegate.sh =="

out=$(STUB_MODE=text "$DELEGATE" "hello" 2>/dev/null); rc=$?
check "normal text passes through" 0 "$rc" "STUB_OK" "$out"

out=$(STUB_MODE=empty "$DELEGATE" "hello" 2>/dev/null); rc=$?
check "empty agy output -> exit 3" 3 "$rc"

out=$(STUB_MODE=fail "$DELEGATE" "hello" 2>/dev/null); rc=$?
check "agy failure -> exit 2" 2 "$rc"

out=$("$DELEGATE" 2>/dev/null); rc=$?
check "no prompt -> exit 1" 1 "$rc"

out=$("$DELEGATE" --bogus "hi" 2>/dev/null); rc=$?
check "unknown option -> exit 1" 1 "$rc"

out=$("$DELEGATE" --tier 2>/dev/null); rc=$?
check "option without value -> exit 1 (friendly)" 1 "$rc"

out=$(STUB_MODE=args "$DELEGATE" --tier flash "hi" 2>/dev/null); rc=$?
check "flash tier -> correct model string" 0 "$rc" "Gemini 3.5 Flash (High)" "$out"

out=$(STUB_MODE=args "$DELEGATE" --tier pro "hi" 2>/dev/null); rc=$?
check "pro tier -> correct model string" 0 "$rc" "Gemini 3.1 Pro (High)" "$out"

out=$(printf 'piped prompt' | STUB_MODE=args "$DELEGATE" - 2>/dev/null); rc=$?
check "stdin prompt (-) read" 0 "$rc" "-p" "$out"

# structured exit codes + machine-readable signal (stderr merged into capture)
out=$(STUB_MODE=quota "$DELEGATE" "hi" 2>&1); rc=$?
check "agy quota -> exit 10 + signal" 10 "$rc" "QUOTA_EXHAUSTED" "$out"

out=$(STUB_MODE=auth "$DELEGATE" "hi" 2>&1); rc=$?
check "agy auth -> exit 11 + signal" 11 "$rc" "AUTH_REQUIRED" "$out"

out=$(STUB_MODE=timeout "$DELEGATE" "hi" 2>&1); rc=$?
check "agy timeout -> exit 12 + signal" 12 "$rc" "TIMEOUT" "$out"

# wall-clock guard: a HANGING agy (sleeps far past the timeout) must be killed and
# mapped to TIMEOUT (exit 12), not hang the wrapper forever (issue #6). Requires a
# real `timeout`/`gtimeout`; skip cleanly if neither is on PATH.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  # outer guard for --timeout 1s = 1 + min-pad(10) = 11s; sleep well past it.
  out=$(STUB_MODE=text STUB_SLEEP=20 "$DELEGATE" --timeout 1s "hi" 2>&1); rc=$?
  check "hanging agy -> wall-clock guard kills it -> exit 12" 12 "$rc" "TIMEOUT" "$out"
else
  echo "ok: (skipped) hang-guard test — no timeout/gtimeout on PATH"; PASS=$((PASS+1))
fi

# userConfig default tier via env; explicit --tier still wins
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_DEFAULT_TIER=pro "$DELEGATE" "hi" 2>/dev/null); rc=$?
check "userConfig default_tier=pro -> Pro model" 0 "$rc" "Gemini 3.1 Pro (High)" "$out"

out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_DEFAULT_TIER=pro "$DELEGATE" --tier flash "hi" 2>/dev/null); rc=$?
check "explicit --tier overrides userConfig" 0 "$rc" "Gemini 3.5 Flash (High)" "$out"

# multi-model: default_model + per-tier remap (agy supports Claude/GPT on some plans)
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL="Claude Sonnet 4.5" "$DELEGATE" "hi" 2>/dev/null); rc=$?
check "userConfig default_model -> used as-is" 0 "$rc" "Claude Sonnet 4.5" "$out"
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL="Claude Sonnet 4.5" "$DELEGATE" --tier flash "hi" 2>/dev/null); rc=$?
check "explicit --tier beats default_model" 0 "$rc" "Gemini 3.5 Flash (High)" "$out"
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL="Claude Sonnet 4.5" "$DELEGATE" -m "GPT-X" "hi" 2>/dev/null); rc=$?
check "explicit --model beats default_model" 0 "$rc" "GPT-X" "$out"
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_TIER_FLASH="Claude Sonnet 4.5" "$DELEGATE" --tier flash "hi" 2>/dev/null); rc=$?
check "tier_flash remap -> flash uses remapped model" 0 "$rc" "Claude Sonnet 4.5" "$out"

# default + userConfig timeout, with explicit flag winning
out=$(STUB_MODE=args "$DELEGATE" "hi" 2>/dev/null); rc=$?
check "default timeout -> --print-timeout 5m" 0 "$rc" "--print-timeout 5m" "$out"
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_TIMEOUT=9m "$DELEGATE" "hi" 2>/dev/null); rc=$?
check "userConfig timeout=9m -> --print-timeout 9m" 0 "$rc" "--print-timeout 9m" "$out"
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_TIMEOUT=9m "$DELEGATE" --timeout 3m "hi" 2>/dev/null); rc=$?
check "explicit --timeout overrides userConfig" 0 "$rc" "--print-timeout 3m" "$out"

# invalid default tier from config falls back to flash; explicit --tier typo still errors
out=$(STUB_MODE=args CLAUDE_PLUGIN_OPTION_DEFAULT_TIER=bogus "$DELEGATE" "hi" 2>/dev/null); rc=$?
check "invalid userConfig tier -> falls back to flash" 0 "$rc" "Gemini 3.5 Flash (High)" "$out"
out=$("$DELEGATE" --tier bogus "hi" 2>/dev/null); rc=$?
check "explicit --tier bogus -> exit 1" 1 "$rc"

# agy missing on PATH -> exit 13 + AGY_MISSING signal (PATH without the stub or real agy)
out=$(PATH="/usr/bin:/bin" "$DELEGATE" "hi" 2>&1); rc=$?
check "agy missing -> exit 13 + AGY_MISSING signal" 13 "$rc" "AGY_MISSING" "$out"

# --print-command: dry run prints the resolved agy invocation and exits 0 (agy not run)
out=$("$DELEGATE" --tier pro --print-command "hi" 2>/dev/null); rc=$?
check "--print-command -> exit 0 + resolved flags" 0 "$rc" "--print-timeout 5m" "$out"
check "--print-command shows the tier model" 0 "$rc" "Pro" "$out"
out=$(PATH="/usr/bin:/bin" "$DELEGATE" --print-command "hi" 2>/dev/null); rc=$?
check "--print-command works without agy on PATH" 0 "$rc" "--print-timeout" "$out"

# WSL slow-mount note: fires only under WSL AND when --add-dir is on /mnt/*
out=$(WSL_DISTRO_NAME=Ubuntu "$DELEGATE" --dir /mnt/c/proj --print-command "hi" 2>&1); rc=$?
check "WSL + /mnt --dir -> slow-mount note" 0 "$rc" "9p bridge" "$out"
out=$(WSL_DISTRO_NAME=Ubuntu "$DELEGATE" --dir /home/u/proj --print-command "hi" 2>&1); rc=$?
if printf '%s' "$out" | grep -q "9p bridge"; then echo "FAIL: slow-mount note fired for a Linux-FS --dir"; FAIL=$((FAIL+1));
else echo "ok: no slow-mount note for a Linux-FS --dir"; PASS=$((PASS+1)); fi

echo "== hooks =="
HOOKS="$ROOT/hooks"

python3 -c "import json; json.load(open('$HOOKS/policy-context.json'))" 2>/dev/null; rc=$?
check "policy-context.json is valid JSON" 0 "$rc"

out=$("$HOOKS/inject-policy.sh" 2>/dev/null); rc=$?
check "inject-policy default on -> emits additionalContext" 0 "$rc" "additionalContext" "$out"
check "inject-policy is cost-aware (not 'delegate everything')" 0 "$rc" "COST-AWARE" "$out"
# the emitted stdout is a well-formed SessionStart hook payload (not just substrings)
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"' 2>/dev/null; rc=$?
check "inject-policy emits valid SessionStart JSON" 0 "$rc"

out=$(CLAUDE_PLUGIN_OPTION_CODING_POLICY=off "$HOOKS/inject-policy.sh" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then echo "ok: inject-policy off -> exit 0 + no output"; PASS=$((PASS+1));
else echo "FAIL: inject-policy off (rc=$rc, out='${out:0:40}')"; FAIL=$((FAIL+1)); fi

# check-agy: exits 0 whether agy is present (stub) or absent, and warns when absent
out=$("$HOOKS/check-agy.sh" 2>/dev/null); rc=$?
check "check-agy (agy present) -> exit 0" 0 "$rc"
err=$( { PATH="/usr/bin:/bin" "$HOOKS/check-agy.sh" >/dev/null; } 2>&1 ); rc=$?
check "check-agy (agy absent) -> exit 0 + warns" 0 "$rc" "not on PATH" "$err"

# hooks.json structural shape (SessionStart command hooks referencing the plugin root)
python3 - "$HOOKS/hooks.json" <<'PY' 2>/dev/null; rc=$?
import json,sys
ss=json.load(open(sys.argv[1]))["hooks"]["SessionStart"]
assert isinstance(ss,list) and ss
for g in ss:
    for h in g["hooks"]:
        assert h["type"]=="command" and "CLAUDE_PLUGIN_ROOT" in h["command"]
PY
check "hooks.json SessionStart shape valid" 0 "$rc"

echo "== delegate subagent guardrail =="
GATE="$HOOKS/validate-delegate-bash.sh"
printf '%s' '{"tool_input":{"command":"X/scripts/agy-delegate.sh --tier flash \"x\""}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows the delegate wrapper -> exit 0" 0 "$rc"
printf '%s' '{"tool_input":{"command":"agy-job.sh start --tier pro \"b\""}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows the job wrapper -> exit 0" 0 "$rc"
printf '%s' '{"tool_input":{"command":"rm -rf /tmp/x ; cat > f.txt"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks arbitrary bash -> exit 2" 2 "$rc"

AGENT="$ROOT/agents/antigravity-delegate.md"
tl=$(grep -m1 '^tools:' "$AGENT")
if [ "$tl" = "tools: Bash, Read, Glob" ]; then echo "ok: delegate agent tools allowlist exact (no Write/Edit)"; PASS=$((PASS+1));
else echo "FAIL: delegate agent tools line unexpected: '$tl'"; FAIL=$((FAIL+1)); fi
if grep -q "PreToolUse" "$AGENT" && grep -q "validate-delegate-bash.sh" "$AGENT"; then
  echo "ok: delegate agent wires the PreToolUse Bash gate"; PASS=$((PASS+1));
else echo "FAIL: delegate agent missing PreToolUse gate"; FAIL=$((FAIL+1)); fi

echo "== measure-session.py =="
SESS="$TMP/sess.jsonl"
cat > "$SESS" <<'JSONL'
{"message":{"role":"user","content":"hi"}}
{"message":{"role":"assistant","usage":{"output_tokens":10,"input_tokens":2,"cache_read_input_tokens":100},"content":[{"type":"tool_use","name":"Bash"}]}}
{"message":{"role":"assistant","usage":{"output_tokens":5}}}
JSONL
out=$(python3 "$MEASURE" "$SESS" "T" 2>/dev/null); rc=$?
# output=15 input=2 cache_read=100 -> weighted = 15*5 + 2 + 100*0.1 = 87 ; total=117 ; turns=2
check "measure: total tokens" 0 "$rc" "TOTAL tokens   117" "$out"
check "measure: cost-weighted" 0 "$rc" "COST-WEIGHTED  87" "$out"
check "measure: turns" 0 "$rc" "turns          2" "$out"
check "measure: tool count" 0 "$rc" "'Bash': 1" "$out"

out=$(python3 "$MEASURE" /no/such/file 2>/dev/null); rc=$?
check "measure: missing file -> exit 1" 1 "$rc"

echo "== agy-job.sh (background jobs) =="
export ANTIGRAVITY_JOBS="$TMP/jobs"
JOB="$ROOT/scripts/agy-job.sh"

id=$(STUB_MODE=text STUB_SLEEP=1 "$JOB" start --tier flash "demo task" 2>/dev/null); rc=$?
check "job start -> exit 0" 0 "$rc"
[ -n "$id" ] && { echo "ok: job start returns id ($id)"; PASS=$((PASS+1)); } || { echo "FAIL: job start id empty"; FAIL=$((FAIL+1)); }

out=$("$JOB" status "$id" 2>/dev/null); rc=$?
check "job status shows running" 0 "$rc" "running" "$out"

for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf '%s' "$("$JOB" status "$id" 2>/dev/null)" | grep -q "state=done" && break
  sleep 0.5
done
out=$("$JOB" result "$id" 2>/dev/null); rc=$?
check "job result -> output when done" 0 "$rc" "STUB_OK" "$out"

cid=$(STUB_MODE=text STUB_SLEEP=10 "$JOB" start --tier flash "long task" 2>/dev/null)
sleep 0.5; "$JOB" cancel "$cid" >/dev/null 2>&1; sleep 0.5
out=$("$JOB" status "$cid" 2>/dev/null)
if printf '%s' "$out" | grep -q "state=running"; then
  echo "FAIL: job cancel (still running)"; FAIL=$((FAIL+1))
else echo "ok: job cancel stops it"; PASS=$((PASS+1)); fi

# structured exit code surfaces through the job layer (quota -> rc 10 + label + signal)
qid=$(STUB_MODE=quota "$JOB" start --tier flash "quota task" 2>/dev/null)
for _ in 1 2 3 4 5 6 7 8; do
  "$JOB" status "$qid" 2>/dev/null | grep -q "rc=10" && break
  sleep 0.5
done
out=$("$JOB" status "$qid" 2>/dev/null)
# require the rendered rc LABEL (guards the rc-from-file fix), not just the signal line
if printf '%s' "$out" | grep -q "rc=10: QUOTA"; then echo "ok: job renders rc=10 label"; PASS=$((PASS+1));
else echo "FAIL: job did not render 'rc=10: QUOTA' label (got: $out)"; FAIL=$((FAIL+1)); fi
if printf '%s' "$out" | grep -q "QUOTA_EXHAUSTED"; then echo "ok: job shows AGY_SIGNAL"; PASS=$((PASS+1));
else echo "FAIL: job did not surface AGY_SIGNAL"; FAIL=$((FAIL+1)); fi

echo "== plugin contract =="
python3 - "$ROOT" <<'PY'
import json, os, re, sys, glob
root = sys.argv[1]
def p(*a): return os.path.join(root, *a)
errs = []
def need(cond, msg):
    if not cond: errs.append(msg)

pj = json.load(open(p(".claude-plugin", "plugin.json")))
need(pj.get("name") == "antigravity", "plugin.json name != antigravity")
need(bool(pj.get("version")), "plugin.json missing version")

mp = json.load(open(p(".claude-plugin", "marketplace.json")))
plugins = mp.get("plugins", [])
need(bool(plugins) and plugins[0].get("source") == "./", "marketplace plugins[0].source != ./")
need(bool(plugins) and plugins[0].get("name") == pj.get("name"), "marketplace plugin name != plugin.json name")

# every SessionStart hook command resolves to a real file
hj = json.load(open(p("hooks", "hooks.json")))
cmds = [h["command"] for grp in hj["hooks"].get("SessionStart", []) for h in grp["hooks"]]
need(bool(cmds), "no SessionStart hook commands")
for c in cmds:
    m = re.search(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\"']+)", c)
    need(bool(m), "hook command missing CLAUDE_PLUGIN_ROOT path: " + c)
    if m: need(os.path.isfile(p(m.group(1))), "hook references missing file: " + m.group(1))

# commands, skill, and agent all carry YAML frontmatter
for f in glob.glob(p("commands", "*.md")) + [p("skills", "antigravity", "SKILL.md"), p("agents", "antigravity-delegate.md")]:
    need(os.path.isfile(f), "missing file: " + f)
    if os.path.isfile(f):
        t = open(f).read()
        need(t.startswith("---") and t.count("---") >= 2, "no YAML frontmatter: " + os.path.basename(f))

# the delegate subagent's PreToolUse gate points at a real script
agent = open(p("agents", "antigravity-delegate.md")).read()
m = re.search(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\"']+\.sh)", agent)
need(bool(m), "agent PreToolUse gate path not found")
if m: need(os.path.isfile(p(m.group(1))), "agent gate references missing file: " + m.group(1))

for s in ("hooks/check-agy.sh", "hooks/inject-policy.sh", "hooks/validate-delegate-bash.sh"):
    need(os.access(p(s), os.X_OK), "not executable: " + s)

if errs:
    print("CONTRACT FAIL:")
    for e in errs: print("  -", e)
    sys.exit(1)
PY
rc=$?
check "plugin contract (manifests, hook/agent refs, frontmatter, exec bits)" 0 "$rc"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
