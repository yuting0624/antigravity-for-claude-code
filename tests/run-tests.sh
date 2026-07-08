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
  big)     printf 'x%.0s' $(seq 1 20000); echo ;;    # dump-sized reply -> digest guard warns
  *)       echo "STUB_OK" ;;
esac
STUB
chmod +x "$TMP/bin/agy"

# --- stub `gcloud` on PATH; logging-read behavior controlled by $GCLOUD_MODE ----
cat > "$TMP/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "config" ]; then echo "stub-project"; exit 0; fi   # config get-value project
if [ "$1" = "logging" ] && [ "$2" = "read" ]; then
  case "${GCLOUD_MODE:-logs}" in
    perm)  echo "ERROR: (gcloud.logging.read) PERMISSION_DENIED: caller does not have permission logging.logEntries.list" >&2; exit 1 ;;
    empty) echo "[]" ;;
    fail)  echo "ERROR: (gcloud.logging.read) something broke" >&2; exit 1 ;;
    big)   pad=$(printf 'A%.0s' {1..3000}); printf '[{"m":"%s"}]TAIL_SENTINEL\n' "$pad" ;;  # large ASCII payload w/ tail marker
    bigjp) pad=$(printf 'あ%.0s' {1..3000}); printf '[{"m":"%s"}]TAIL_SENTINEL\n' "$pad" ;;  # large multibyte (3-byte/char) payload
    *)     echo '[{"severity":"ERROR","textPayload":"KeyError: DATABASE_URL","timestamp":"2026-06-28T00:00:00Z"}]' ;;
  esac
  exit 0
fi
echo "gcloud-stub: unhandled args: $*" >&2; exit 99
STUB
chmod +x "$TMP/bin/gcloud"

export PATH="$TMP/bin:$PATH"

# A minimal PATH dir with common utils but deliberately NO gcloud/agy, so
# "missing on PATH" tests stay deterministic on runners that ship gcloud in
# /usr/bin (GitHub-hosted ubuntu does — so PATH=/usr/bin:/bin would still find it).
mkdir -p "$TMP/min"
for u in bash sh env dirname basename pwd sed cat mktemp grep tr cut find wc head tail sort uniq sleep python3 rm chmod; do
  s="$(command -v "$u" 2>/dev/null)" && ln -sf "$s" "$TMP/min/$u"
done

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

# write-task without write permission -> warn (describe-only pre-1.1.0, scratch-divert on 1.1.0) (issue #10)
out=$(STUB_MODE=args "$DELEGATE" "implement the parser module" 2>&1); rc=$?
check "write prompt w/o write permission -> warns" 0 "$rc" "scratch dir" "$out"
out=$(STUB_MODE=args "$DELEGATE" --yolo "implement the parser module" 2>&1); rc=$?
if printf '%s' "$out" | grep -q "scratch dir"; then echo "FAIL: warned even with --yolo"; FAIL=$((FAIL+1));
else echo "ok: no write-warning when --yolo is set"; PASS=$((PASS+1)); fi
out=$(STUB_MODE=args "$DELEGATE" --mode accept-edits "implement the parser module" 2>&1); rc=$?
if printf '%s' "$out" | grep -q "scratch dir"; then echo "FAIL: warned even with --mode accept-edits"; FAIL=$((FAIL+1));
else echo "ok: no write-warning with --mode accept-edits"; PASS=$((PASS+1)); fi
out=$(STUB_MODE=args "$DELEGATE" "summarize the changelog in 3 bullets" 2>&1); rc=$?
if printf '%s' "$out" | grep -q "scratch dir"; then echo "FAIL: warned for a non-write prompt"; FAIL=$((FAIL+1));
else echo "ok: no write-warning for a read/summary prompt"; PASS=$((PASS+1)); fi

# --mode passthrough (agy >= 1.1.0): accept-edits reaches agy; invalid mode errors early
out=$(STUB_MODE=args "$DELEGATE" --mode accept-edits "hi" 2>/dev/null); rc=$?
check "--mode accept-edits passed through to agy" 0 "$rc" "--mode accept-edits" "$out"
out=$(STUB_MODE=args "$DELEGATE" --mode plan "hi" 2>/dev/null); rc=$?
check "--mode plan passed through to agy" 0 "$rc" "--mode plan" "$out"
out=$("$DELEGATE" --mode bogus "hi" 2>&1); rc=$?
check "--mode bogus -> exit 1 (friendly)" 1 "$rc" "invalid --mode" "$out"
out=$("$DELEGATE" --mode accept-edits --print-command "hi" 2>/dev/null); rc=$?
check "--print-command shows --mode" 0 "$rc" "--mode accept-edits" "$out"

# --digest appends the digest-only output contract to the prompt (issue #5)
out=$(STUB_MODE=args "$DELEGATE" --digest "hi" 2>/dev/null); rc=$?
check "--digest appends the output contract" 0 "$rc" "OUTPUT CONTRACT (digest)" "$out"
out=$("$DELEGATE" --help); rc=$?
check "usage documents --digest" 0 "$rc" "--digest" "$out"

# digest-size guard: dump-sized reply -> stderr note; small reply -> silent; 0 disables
out=$(STUB_MODE=big "$DELEGATE" "hi" 2>&1 >/dev/null); rc=$?
check "dump-sized output -> raw-dump note on stderr" 0 "$rc" "raw dump" "$out"
out=$(STUB_MODE=text "$DELEGATE" "hi" 2>&1 >/dev/null)
if printf '%s' "$out" | grep -q "raw dump"; then echo "FAIL: digest guard fired on a small reply"; FAIL=$((FAIL+1));
else echo "ok: digest guard silent on a small reply"; PASS=$((PASS+1)); fi
out=$(STUB_MODE=big CLAUDE_PLUGIN_OPTION_DIGEST_WARN_CHARS=0 "$DELEGATE" "hi" 2>&1 >/dev/null)
if printf '%s' "$out" | grep -q "raw dump"; then echo "FAIL: digest guard fired with digest_warn_chars=0"; FAIL=$((FAIL+1));
else echo "ok: digest_warn_chars=0 disables the guard"; PASS=$((PASS+1)); fi
out=$(STUB_MODE=text CLAUDE_PLUGIN_OPTION_DIGEST_WARN_CHARS=5 "$DELEGATE" "hi" 2>&1 >/dev/null); rc=$?
check "custom digest_warn_chars threshold respected" 0 "$rc" "raw dump" "$out"

# WSL slow-mount note: fires only under WSL AND when --add-dir is on /mnt/*
out=$(WSL_DISTRO_NAME=Ubuntu "$DELEGATE" --dir /mnt/c/proj --print-command "hi" 2>&1); rc=$?
check "WSL + /mnt --dir -> slow-mount note" 0 "$rc" "9p bridge" "$out"
out=$(WSL_DISTRO_NAME=Ubuntu "$DELEGATE" --dir /home/u/proj --print-command "hi" 2>&1); rc=$?
if printf '%s' "$out" | grep -q "9p bridge"; then echo "FAIL: slow-mount note fired for a Linux-FS --dir"; FAIL=$((FAIL+1));
else echo "ok: no slow-mount note for a Linux-FS --dir"; PASS=$((PASS+1)); fi

echo "== cloud-debug.sh (Cloud Run log digest engine) =="
CLOUD="$ROOT/scripts/cloud-debug.sh"

# (a) logs fetched -> handed to agy -> digest printed (exit 0). agy stub -> STUB_OK.
out=$(GCLOUD_MODE=logs "$CLOUD" --service svc 2>/dev/null); rc=$?
check "logs -> agy digest -> exit 0" 0 "$rc" "STUB_OK" "$out"

# (b) --since defaults to 1h; an explicit --since wins. (dry run; no calls made)
out=$("$CLOUD" --service svc --print-command 2>/dev/null); rc=$?
check "default --since -> --freshness=1h" 0 "$rc" "--freshness=1h" "$out"
out=$("$CLOUD" --service svc --since 3h --print-command 2>/dev/null); rc=$?
check "explicit --since overrides default" 0 "$rc" "--freshness=3h" "$out"

# the resolved gcloud verb is READ-only (logging read), and the resource type is
# parameterized (default cloud_run_revision; overridable for a future gke/functions cmd)
check "engine uses read-only 'logging read'" 0 "$rc" "logging read" "$out"
out=$("$CLOUD" --service svc --print-command 2>/dev/null); rc=$?
check "default resource type is cloud_run_revision" 0 "$rc" "cloud_run_revision" "$out"
out=$("$CLOUD" --service svc --resource-type k8s_container --print-command 2>/dev/null); rc=$?
check "--resource-type is parameterized" 0 "$rc" "k8s_container" "$out"

# lean handoff: gcloud --format PROJECTS only the digest fields (not raw json),
# dropping resource/insertId noise — shrinks the payload sent to agy.
out=$("$CLOUD" --service svc --print-command 2>/dev/null); rc=$?
check "gcloud --format projects digest fields (httpRequest.status)" 0 "$rc" "httpRequest.status" "$out"
check "gcloud --format keeps the message body (jsonPayload)" 0 "$rc" "jsonPayload" "$out"

# (c) read-only: no --apply path in the engine, and a real run writes no files to CWD.
out=$("$CLOUD" --service svc --apply 2>/dev/null); rc=$?
check "engine rejects --apply (write path is command-level, not here)" 1 "$rc"
WORK="$TMP/cdwork"; mkdir -p "$WORK"
( cd "$WORK" && GCLOUD_MODE=logs "$CLOUD" --service svc >/dev/null 2>&1 )
nf=$(find "$WORK" -type f | wc -l)
if [ "$nf" -eq 0 ]; then echo "ok: a diagnosis run writes no files to the project"; PASS=$((PASS+1));
else echo "FAIL: cloud-debug wrote $nf file(s) to CWD on a read-only run"; FAIL=$((FAIL+1)); fi

# (d) missing roles/logging.viewer -> exit 3 with actionable guidance
out=$(GCLOUD_MODE=perm "$CLOUD" --service svc 2>&1); rc=$?
check "permission denied -> exit 3 + logging.viewer guidance" 3 "$rc" "logging.viewer" "$out"

# misc: required --service, generic gcloud failure, gcloud missing, no logs
out=$("$CLOUD" 2>/dev/null); rc=$?
check "missing --service -> exit 1" 1 "$rc"
out=$(GCLOUD_MODE=fail "$CLOUD" --service svc 2>/dev/null); rc=$?
check "generic gcloud failure -> exit 2" 2 "$rc"
out=$(PATH="$TMP/min" "$CLOUD" --service svc 2>&1); rc=$?
check "gcloud missing on PATH -> exit 4" 4 "$rc" "gcloud" "$out"
out=$(GCLOUD_MODE=empty "$CLOUD" --service svc 2>/dev/null); rc=$?
check "no matching logs -> exit 0 + clear note" 0 "$rc" "no logs" "$out"

# agy digest step failure surfaces as exit 5 (logs fetched fine, agy errored)
out=$(GCLOUD_MODE=logs STUB_MODE=fail "$CLOUD" --service svc 2>/dev/null); rc=$?
check "agy digest failure -> exit 5" 5 "$rc"

# byte cap (backstop): a big payload + a tiny CLOUD_DEBUG_MAX_BYTES -> the tail is
# clipped before agy and the instruction tells agy what happened.
out=$(GCLOUD_MODE=big STUB_MODE=args CLOUD_DEBUG_MAX_BYTES=50 "$CLOUD" --service svc 2>/dev/null); rc=$?
check "byte cap -> clip NOTE handed to agy" 0 "$rc" "clipped to 50 bytes" "$out"
check "byte cap NOTE warns the JSON is now invalid" 0 "$rc" "no longer valid JSON" "$out"
if printf '%s' "$out" | grep -q "TAIL_SENTINEL"; then
  echo "FAIL: payload tail not clipped (sentinel survived the cap)"; FAIL=$((FAIL+1));
else echo "ok: payload clipped to the cap (tail dropped before agy)"; PASS=$((PASS+1)); fi
# the cap is BYTE-based, so a multibyte (3-byte/char) payload is clipped too
out=$(GCLOUD_MODE=bigjp STUB_MODE=args CLOUD_DEBUG_MAX_BYTES=50 "$CLOUD" --service svc 2>/dev/null); rc=$?
check "byte cap clips a multibyte payload too" 0 "$rc" "clipped to 50 bytes" "$out"
if printf '%s' "$out" | grep -q "TAIL_SENTINEL"; then
  echo "FAIL: multibyte payload tail not clipped (cap counting chars, not bytes?)"; FAIL=$((FAIL+1));
else echo "ok: multibyte payload clipped (byte-accurate cap)"; PASS=$((PASS+1)); fi
# under the cap -> no clip NOTE (no false positives on a normal payload)
out=$(GCLOUD_MODE=logs STUB_MODE=args "$CLOUD" --service svc 2>/dev/null); rc=$?
if printf '%s' "$out" | grep -q "clipped to"; then
  echo "FAIL: clip NOTE on a payload under the cap"; FAIL=$((FAIL+1));
else echo "ok: no clip NOTE when under the cap"; PASS=$((PASS+1)); fi

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

# hooks.json structural shape (all events: command hooks referencing the plugin root)
python3 - "$HOOKS/hooks.json" <<'PY' 2>/dev/null; rc=$?
import json,sys
hooks=json.load(open(sys.argv[1]))["hooks"]
assert hooks.get("SessionStart") and hooks.get("UserPromptSubmit")
for groups in hooks.values():
    assert isinstance(groups,list) and groups
    for g in groups:
        for h in g["hooks"]:
            assert h["type"]=="command" and "CLAUDE_PLUGIN_ROOT" in h["command"]
PY
check "hooks.json shape valid (SessionStart + UserPromptSubmit)" 0 "$rc"

# nudge-delegation (UserPromptSubmit): advisory material only — never a mandate
NUDGE="$HOOKS/nudge-delegation.sh"
out=$(printf '%s' '{"prompt":"migrate every caller from APIv1 to APIv2 across the codebase"}' | "$NUDGE" 2>/dev/null); rc=$?
check "nudge fires on bulk EN prompt" 0 "$rc" "additionalContext" "$out"
check "nudge preserves Claude's judgment (not a mandate)" 0 "$rc" "THE JUDGMENT IS YOURS" "$out"
printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['hookSpecificOutput']['hookEventName']=='UserPromptSubmit'" 2>/dev/null; rc=$?
check "nudge emits valid UserPromptSubmit JSON" 0 "$rc"
out=$(printf '%s' '{"prompt":"リポジトリ全体のテストを網羅的に生成して"}' | "$NUDGE" 2>/dev/null); rc=$?
check "nudge fires on bulk JA prompt" 0 "$rc" "additionalContext" "$out"
out=$(printf '%s' '{"prompt":"fix the typo in README"}' | "$NUDGE" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then echo "ok: nudge silent on a small prompt"; PASS=$((PASS+1));
else echo "FAIL: nudge fired on a small prompt (rc=$rc)"; FAIL=$((FAIL+1)); fi
out=$(printf '%s' '{"prompt":"/antigravity:delegate migrate everything"}' | "$NUDGE" 2>/dev/null)
if [ -z "$out" ]; then echo "ok: nudge silent when already delegating"; PASS=$((PASS+1));
else echo "FAIL: nudge fired on an antigravity command"; FAIL=$((FAIL+1)); fi
out=$(printf '%s' '{"prompt":"migrate all files"}' | CLAUDE_PLUGIN_OPTION_DELEGATION_NUDGE=off "$NUDGE" 2>/dev/null)
if [ -z "$out" ]; then echo "ok: delegation_nudge=off suppresses the nudge"; PASS=$((PASS+1));
else echo "FAIL: nudge fired while disabled"; FAIL=$((FAIL+1)); fi
out=$(printf '%s' '{"prompt":"hello","cwd":"/home/u/migration-tool"}' | "$NUDGE" 2>/dev/null)
if [ -z "$out" ]; then echo "ok: nudge scans only the prompt field (cwd noise ignored)"; PASS=$((PASS+1));
else echo "FAIL: nudge matched a non-prompt field"; FAIL=$((FAIL+1)); fi

echo "== delegate subagent guardrail =="
GATE="$HOOKS/validate-delegate-bash.sh"
printf '%s' '{"tool_input":{"command":"X/scripts/agy-delegate.sh --tier flash \"x\""}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows the delegate wrapper -> exit 0" 0 "$rc"
printf '%s' '{"tool_input":{"command":"agy-job.sh start --tier pro \"b\""}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows the job wrapper -> exit 0" 0 "$rc"
printf '%s' '{"tool_input":{"command":"rm -rf /tmp/x ; cat > f.txt"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks arbitrary bash -> exit 2" 2 "$rc"
# gate also accepts the bin-name entrypoints (no .sh) the subagent now calls (issue #11)
printf '%s' '{"tool_input":{"command":"agy-delegate --tier flash \"x\""}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows bin name agy-delegate -> exit 0" 0 "$rc"
printf '%s' '{"tool_input":{"command":"agy-job status abc"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows bin name agy-job -> exit 0" 0 "$rc"

AGENT="$ROOT/agents/antigravity-delegate.md"
tl=$(grep -m1 '^tools:' "$AGENT")
if [ "$tl" = "tools: Bash, Read, Glob" ]; then echo "ok: delegate agent tools allowlist exact (no Write/Edit)"; PASS=$((PASS+1));
else echo "FAIL: delegate agent tools line unexpected: '$tl'"; FAIL=$((FAIL+1)); fi
if grep -q "PreToolUse" "$AGENT" && grep -q "validate-delegate-bash.sh" "$AGENT"; then
  echo "ok: delegate agent wires the PreToolUse Bash gate"; PASS=$((PASS+1));
else echo "FAIL: delegate agent missing PreToolUse gate"; FAIL=$((FAIL+1)); fi
# proactive auto-selection, WITH the judgment kept on Claude (not "delegate everything")
if grep -q "PROACTIVELY" "$AGENT" && grep -q "break-even judgment is yours" "$AGENT"; then
  echo "ok: delegate agent is proactive AND keeps the break-even judgment"; PASS=$((PASS+1));
else echo "FAIL: delegate agent missing proactive-with-judgment description"; FAIL=$((FAIL+1)); fi

echo "== bin/ entrypoints (issue #11: \$CLAUDE_PLUGIN_ROOT not on model-run Bash) =="
BIN="$ROOT/bin"
for b in agy-delegate agy-job agy-cost-compare agy-doctor cloud-debug agy-trace; do
  if [ -x "$BIN/$b" ]; then echo "ok: bin/$b executable"; PASS=$((PASS+1));
  else echo "FAIL: bin/$b missing or not executable"; FAIL=$((FAIL+1)); fi
done
# the shim must forward to scripts/ without needing $CLAUDE_PLUGIN_ROOT in the env
out=$(env -u CLAUDE_PLUGIN_ROOT "$BIN/agy-delegate" --tier pro --print-command "hi" 2>/dev/null); rc=$?
check "bin/agy-delegate forwards to the wrapper (no CLAUDE_PLUGIN_ROOT)" 0 "$rc" "--print-timeout" "$out"
out=$(env -u CLAUDE_PLUGIN_ROOT "$BIN/agy-doctor" 2>/dev/null | head -1); rc=$?
case "$out" in *doctor*) echo "ok: bin/agy-doctor forwards to doctor.sh"; PASS=$((PASS+1));;
  *) echo "FAIL: bin/agy-doctor did not forward (got: '$out')"; FAIL=$((FAIL+1));; esac
out=$(env -u CLAUDE_PLUGIN_ROOT "$BIN/cloud-debug" --service svc --print-command 2>/dev/null); rc=$?
check "bin/cloud-debug forwards to cloud-debug.sh (no CLAUDE_PLUGIN_ROOT)" 0 "$rc" "logging read" "$out"

echo "== agy-trace.sh (subagent trajectory reader) =="
TRACE="$ROOT/scripts/agy-trace.sh"
# fixture: a brain dir with one subagent transcript (shape matches agy 1.0.12)
FIXBRAIN="$TMP/brain"
mkdir -p "$FIXBRAIN/conv-123/.system_generated/logs"
cat > "$FIXBRAIN/conv-123/.system_generated/logs/transcript.jsonl" <<'JSONL'
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>do the thing</USER_REQUEST>"}
{"step_index":1,"source":"SYSTEM","type":"PLANNER_RESPONSE","status":"DONE","content":"I did the thing and reported back."}
JSONL
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" conv-123 2>&1); rc=$?
check "trace by conversationId -> pretty steps" 0 "$rc" "USER_INPUT" "$out"
check "trace shows planner step" 0 "$rc" "PLANNER_RESPONSE" "$out"
out=$("$TRACE" "$FIXBRAIN/conv-123/.system_generated/logs/transcript.jsonl" 2>&1); rc=$?
check "trace by literal path works" 0 "$rc" "USER_INPUT" "$out"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --raw conv-123 2>&1); rc=$?
check "--raw emits raw JSONL" 0 "$rc" '"step_index":0' "$out"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --list 2>&1); rc=$?
check "--list shows the transcript" 0 "$rc" "conv-123" "$out"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" no-such-conv 2>&1); rc=$?
check "unknown conversationId -> exit 2" 2 "$rc" "no transcript" "$out"
out=$(env -u CLAUDE_PLUGIN_ROOT AGY_BRAIN_DIR="$FIXBRAIN" "$BIN/agy-trace" conv-123 2>&1); rc=$?
check "bin/agy-trace forwards (no CLAUDE_PLUGIN_ROOT)" 0 "$rc" "USER_INPUT" "$out"

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

# SKILL.md version frontmatter must track plugin.json (PR #14 drifted them: a version
# bump that forgets the skill leaves stale docs and breaks update recognition reasoning)
skill_txt = open(p("skills", "antigravity", "SKILL.md")).read()
sm = re.search(r"(?m)^version:\s*(\S+)\s*$", skill_txt)
need(bool(sm), "SKILL.md missing version frontmatter")
if sm: need(sm.group(1) == pj.get("version"),
            "SKILL.md version (%s) != plugin.json version (%s)" % (sm.group(1), pj.get("version")))

mp = json.load(open(p(".claude-plugin", "marketplace.json")))
plugins = mp.get("plugins", [])
need(bool(plugins) and plugins[0].get("source") == "./", "marketplace plugins[0].source != ./")
need(bool(plugins) and plugins[0].get("name") == pj.get("name"), "marketplace plugin name != plugin.json name")

# every hook command (all events) resolves to a real file
hj = json.load(open(p("hooks", "hooks.json")))
cmds = [h["command"] for groups in hj["hooks"].values() for grp in groups for h in grp["hooks"]]
need(bool(cmds), "no hook commands")
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

for s in ("hooks/check-agy.sh", "hooks/inject-policy.sh", "hooks/validate-delegate-bash.sh", "hooks/nudge-delegation.sh"):
    need(os.access(p(s), os.X_OK), "not executable: " + s)

# bin/ entrypoints exist + executable (issue #11: $CLAUDE_PLUGIN_ROOT isn't exported
# to model-run Bash, so commands/skill must call these bare names on the PATH)
for b in ("agy-delegate", "agy-job", "agy-cost-compare", "agy-doctor", "cloud-debug", "agy-trace"):
    need(os.access(p("bin", b), os.X_OK), "bin entrypoint missing/not executable: bin/" + b)

# regression guard: commands & skill must NOT invoke $CLAUDE_PLUGIN_ROOT/scripts/* — that
# path expands empty on marketplace installs (issue #11). They must use the bin names.
for f in glob.glob(p("commands", "*.md")) + [p("skills", "antigravity", "SKILL.md")]:
    if os.path.isfile(f):
        t = open(f).read()
        need("CLAUDE_PLUGIN_ROOT}/scripts/" not in t and "CLAUDE_PLUGIN_ROOT/scripts/" not in t,
             "invokes $CLAUDE_PLUGIN_ROOT/scripts (empty on model Bash, issue #11): " + os.path.basename(f))

# regression guard: any SessionStart `additionalContext` injected into the MODEL must not
# reference $CLAUDE_PLUGIN_ROOT — it isn't exported to model-run Bash, so the model gets an
# empty path and the instruction fails (issue #15). Structured hook *command* fields are
# exempt (substitution works there) — only injected context strings are checked.
def _ctx_strings(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "additionalContext" and isinstance(v, str): yield v
            else: yield from _ctx_strings(v)
    elif isinstance(o, list):
        for x in o: yield from _ctx_strings(x)
for hf in glob.glob(p("hooks", "*.json")):
    try: hd = json.load(open(hf))
    except Exception: continue
    for ac in _ctx_strings(hd):
        need("CLAUDE_PLUGIN_ROOT" not in ac,
             "injected additionalContext references $CLAUDE_PLUGIN_ROOT (empty on model Bash, issue #15): " + os.path.basename(hf))

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
