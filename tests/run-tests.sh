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
# `agy models` emits the slug format agy 1.1.5+ uses (was display names before) so doctor's
# tier-model check is exercised against the current format.
if [ "$1" = "models" ]; then
  printf '%s\n' gemini-3.6-flash-high gemini-3.5-flash gemini-3.5-flash-low gemini-3.1-pro-high
  exit 0
fi
# `agy --help`: advertise --output-format only when STUB_JSON_CAPABLE=1, so tests can
# exercise both the structured (agy >= 1.1.8) and the plain-text fallback paths.
if [ "$1" = "--help" ]; then
  [ "${STUB_JSON_CAPABLE:-0}" = "1" ] && echo "  --output-format  Output format for print mode (text, json, stream-json)"
  echo "  --print-timeout  timeout"
  exit 0
fi
case "${STUB_MODE:-text}" in
  empty)   exit 0 ;;                  # no stdout -> wrapper should exit 3
  fail)    echo "boom" >&2; exit 7 ;; # nonzero  -> wrapper should exit 2
  args)    printf '%s\n' "$*" ;;      # echo args for assertions
  quota)   echo "Error: quota exceeded for this model" >&2; exit 1 ;;     # -> wrapper exit 10
  auth)    echo "Error: request is unauthenticated; please sign in" >&2; exit 1 ;; # -> exit 11
  timeout) echo "Error: deadline exceeded (the request timed out)" >&2; exit 1 ;;  # -> exit 12
  badmodel) echo "Error: invalid --model \"X\": model X is not recognized as a known model" >&2; exit 1 ;; # -> exit 14
  softdeny) echo "no output produced — a tool required the \"write_file\" permission that headless mode cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow" >&2; exit 0 ;; # rc=0 + empty stdout -> exit 15
  big)     printf 'x%.0s' $(seq 1 20000); echo ;;    # dump-sized reply -> digest guard warns
  # agy >= 1.1.8 structured envelope. Note the RAW newline inside "response" — agy really
  # emits that, and it makes the payload invalid for strict JSON parsers.
  json_ok)  printf '{"conversation_id":"c1","status":"SUCCESS","response":"JSONBODY\n","usage":{"input_tokens":10,"output_tokens":2,"thinking_tokens":1,"cache_read_tokens":3,"total_tokens":16}}'; exit 0 ;;
  json_err) printf '{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection: model X is not recognized as a known model","usage":{}}'; exit 1 ;;
  # Same failure, but with agy's REAL wording — it quotes the offending value. The
  # diagnostic text sits AFTER the embedded quotes, so any field extraction that stops
  # at the first `"` loses it and the failure misclassifies. This is what shipped.
  json_err_quoted) printf '{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection (--model \\"X\\" --effort \\"\\"): model X is not recognized as a known model or custom model in settings","usage":{}}'; exit 1 ;;
  json_quota) printf '{"conversation_id":"","status":"ERROR","response":"","error":"quota exceeded for this model","usage":{}}'; exit 1 ;;
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

out=$(STUB_MODE=badmodel "$DELEGATE" "hi" 2>&1); rc=$?
check "agy bad --model -> exit 14 + signal" 14 "$rc" "MODEL_UNAVAILABLE" "$out"

# agy >= 1.1.8 structured output: used internally, stdout contract unchanged
out=$(STUB_JSON_CAPABLE=1 STUB_MODE=json_ok "$DELEGATE" "hi" 2>/dev/null); rc=$?
check "json mode: stdout carries the response text (not the envelope)" 0 "$rc" "JSONBODY" "$out"
# Regression: the capability probe must not pipe into `grep -q`. That closes the pipe on
# the first match, `agy --help` can die of SIGPIPE, and under `set -o pipefail` the probe
# silently reads as "unsupported" -> JSON mode off with no AGY_USAGE, indistinguishable
# from "no delegation happened". Observed at ~75% failure on a loaded container.
if sed 's/#.*//' "$DELEGATE" | grep -qE 'agy --help[^|]*\| *grep'; then
  echo "FAIL: capability probe pipes agy --help into grep (SIGPIPE race under pipefail)"; FAIL=$((FAIL+1));
else echo "ok: capability probe avoids the grep pipe (no SIGPIPE race)"; PASS=$((PASS+1)); fi
# Under load the probe must still be deterministic: run the real gate shape 20x.
probe_off=0
for _ in $(seq 1 20); do
  STUB_JSON_CAPABLE=1 bash -c '
    set -euo pipefail
    h="$(agy --help 2>&1 || true)"
    case "$h" in *--output-format*) exit 0 ;; esac
    exit 1' >/dev/null 2>&1 || probe_off=$((probe_off+1))
done
if [ "$probe_off" -eq 0 ]; then echo "ok: capability probe stable over 20 runs"; PASS=$((PASS+1));
else echo "FAIL: capability probe flaked $probe_off/20 times"; FAIL=$((FAIL+1)); fi

# The --help probe must be wall-clock bounded like the main call. It was the one
# unguarded `agy` invocation left: the timeout resolver used to be initialised
# after it. A hang here is not hypothetical — doctor's own MCP hint documents a
# blocking mode that survives the issue-37 fix.
if sed 's/#.*//' "$DELEGATE" | grep -qE '"\$TO_CMD"[^|]*agy --help'; then
  echo "ok: the --help capability probe is wall-clock bounded"; PASS=$((PASS+1));
else echo "FAIL: --help probe runs unguarded (no timeout)"; FAIL=$((FAIL+1)); fi
if [ "$(sed 's/#.*//' "$DELEGATE" | grep -n 'TO_CMD="\$(timeout_cmd' | cut -d: -f1)" \
   -lt "$(sed 's/#.*//' "$DELEGATE" | grep -n 'agy --help' | head -1 | cut -d: -f1)" ]; then
  echo "ok: the timeout resolver is initialised before the probe uses it"; PASS=$((PASS+1));
else echo "FAIL: TO_CMD resolved after the --help probe — the guard is a no-op"; FAIL=$((FAIL+1)); fi

# --- issue #37: never capture agy through a pipe ------------------------------
# agy's stdio MCP children INHERIT its stdout and outlive it, so they hold the
# write end of a command-substitution pipe open and `$(agy ...)` never sees EOF.
# The `timeout` guard cannot save this: it kills agy, not the grandchildren. The
# only fix is to not use a pipe, so guard the shape rather than the symptom —
# a hang cannot be asserted on cheaply, and the next refactor is where it comes
# back. Both the main call and the --help probe were affected.
if sed 's/#.*//' "$DELEGATE" | grep -qE '=[[:space:]]*"?\$\((\$?[A-Za-z_"]*TO_CMD"?[^)]*)?[[:space:]]*agy[[:space:]]'; then
  echo "FAIL: agy captured through a command substitution (issue #37 pipe hang)"; FAIL=$((FAIL+1));
else echo "ok: agy output is never captured through a pipe (issue #37)"; PASS=$((PASS+1)); fi
if sed 's/#.*//' "$ROOT/scripts/doctor.sh" | grep -qE '^[[:space:]]*(agy|"\$TO_CMD")[^>|]*$' \
   && ! grep -q 'cat "\$f"' "$ROOT/scripts/doctor.sh"; then
  echo "FAIL: doctor's agy_guard writes to the caller's pipe (issue #37)"; FAIL=$((FAIL+1));
else echo "ok: doctor's agy_guard redirects to a file, cat is the only pipe writer"; PASS=$((PASS+1)); fi
# The mechanism itself, against a stub that behaves like agy+MCP: spawn a child
# that inherits stdout and outlives the parent. Pipe form must hang; file form
# must return. Bounded so a regression costs 5s, not the whole suite.
MCPBIN="$TMP/mcpstub"; mkdir -p "$MCPBIN"
cat > "$MCPBIN/agy" <<'STUB'
#!/usr/bin/env bash
sleep 30 &        # the "MCP server": inherits our stdout, outlives us
echo "PONG"
exit 0
STUB
chmod +x "$MCPBIN/agy"
if PATH="$MCPBIN:$PATH" timeout 5 bash -c 'O="$(agy -p x </dev/null 2>/dev/null)"' >/dev/null 2>&1; then
  echo "FAIL: stub did not reproduce the pipe hang — the test no longer proves anything"; FAIL=$((FAIL+1));
else echo "ok: stub reproduces the inherited-stdout pipe hang"; PASS=$((PASS+1)); fi
# NOT `out`: the pre-existing json-envelope check below reads that variable, and
# clobbering it here made that assertion pass unconditionally — silently, with PASS
# still incrementing. A test that passes for the wrong reason is worse than no test.
mcp_out=$(PATH="$MCPBIN:$PATH" timeout 5 bash -c 'f="$(mktemp)"; agy -p x </dev/null >"$f" 2>/dev/null; cat "$f"; rm -f "$f"' 2>/dev/null)
check "the file form returns against the same stub" 0 "$?" "PONG" "$mcp_out"
# Liveness first: a negative assertion on an empty variable passes for free, and
# this one sat 50 lines from where `out` is set — far enough that an insertion in
# between silently emptied it once already.
if [ -z "$out" ]; then
  echo "FAIL: \$out is empty at the envelope check — the assertion below proves nothing"; FAIL=$((FAIL+1));
else echo "ok: \$out still holds the json_ok reply at the envelope check"; PASS=$((PASS+1)); fi
if printf '%s' "$out" | grep -q 'conversation_id'; then
  echo "FAIL: json envelope leaked to stdout"; FAIL=$((FAIL+1));
else echo "ok: json envelope does not leak to stdout"; PASS=$((PASS+1)); fi
err=$(STUB_JSON_CAPABLE=1 STUB_MODE=json_ok "$DELEGATE" "hi" 2>&1 >/dev/null); rc=$?
check "json mode: token usage reported as AGY_USAGE on stderr" 0 "$rc" "AGY_USAGE" "$err"
check "json mode: usage includes cache_read" 0 "$rc" '"cache_read": 3' "$err"
# classification now comes from the structured error (stderr is empty in json mode)
out=$(STUB_JSON_CAPABLE=1 STUB_MODE=json_err "$DELEGATE" "hi" 2>&1); rc=$?
check "json mode: structured error -> exit 14 + signal" 14 "$rc" "MODEL_UNAVAILABLE" "$out"
# Regression: agy quotes the offending value in its error, and the diagnostic phrase
# comes AFTER those quotes. Extracting the field with sed truncated at the first
# escaped quote, so the classifier never saw it and a bad --model/tier remap reported a
# generic "agy failed" (exit 2) instead of MODEL_UNAVAILABLE. The old stub had no
# embedded quotes, which is exactly why the tests stayed green while this shipped.
out=$(STUB_JSON_CAPABLE=1 STUB_MODE=json_err_quoted "$DELEGATE" "hi" 2>&1); rc=$?
check "json mode: error containing quotes still classifies (exit 14)" 14 "$rc" "MODEL_UNAVAILABLE" "$out"
check "json mode: quoted error yields the actionable hint" 14 "$rc" "not available on this plan" "$out"
out=$(STUB_JSON_CAPABLE=1 STUB_MODE=json_quota "$DELEGATE" "hi" 2>&1); rc=$?
check "json mode: structured quota error -> exit 10" 10 "$rc" "QUOTA_EXHAUSTED" "$out"
# opt-out and capability fallback both take the plain-text path (no AGY_USAGE)
err=$(STUB_JSON_CAPABLE=1 STUB_MODE=text CLAUDE_PLUGIN_OPTION_STRUCTURED_OUTPUT=off "$DELEGATE" "hi" 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q "AGY_USAGE"; then echo "FAIL: structured_output=off still used json"; FAIL=$((FAIL+1));
else echo "ok: structured_output=off falls back to plain text"; PASS=$((PASS+1)); fi
err=$(STUB_JSON_CAPABLE=0 STUB_MODE=text "$DELEGATE" "hi" 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q "AGY_USAGE"; then echo "FAIL: used json against an agy that lacks the flag"; FAIL=$((FAIL+1));
else echo "ok: falls back when agy has no --output-format (pre-1.1.8)"; PASS=$((PASS+1)); fi

# --- AGY_USAGE_LOG side channel ---------------------------------------------
# Regression guard for a measurement loss seen in the wild: stderr carries the
# usage line, but a conductor keeping its context lean writes `2>&1 | tail -N`,
# stdout (the digest) is emitted after it, and `tail` drops the usage line. The
# named file must survive that exact pipeline.
ULOG="$TMP/usage.log"
rm -f "$ULOG"
STUB_JSON_CAPABLE=1 STUB_MODE=json_ok AGY_USAGE_LOG="$ULOG" "$DELEGATE" "hi" >/dev/null 2>&1
if [ -s "$ULOG" ] && grep -q '^AGY_USAGE ' "$ULOG"; then
  echo "ok: AGY_USAGE_LOG captures the usage line"; PASS=$((PASS+1));
else echo "FAIL: AGY_USAGE_LOG did not capture AGY_USAGE"; FAIL=$((FAIL+1)); fi
rm -f "$ULOG"
STUB_JSON_CAPABLE=1 STUB_MODE=json_ok AGY_USAGE_LOG="$ULOG" \
  bash -c '"$1" hi 2>&1 | tail -1 >/dev/null' _ "$DELEGATE" || true
if grep -q '^AGY_USAGE ' "$ULOG" 2>/dev/null; then
  echo "ok: AGY_USAGE_LOG survives '2>&1 | tail -N' (the measured loss)"; PASS=$((PASS+1));
else echo "FAIL: AGY_USAGE_LOG lost the usage line through a tail pipeline"; FAIL=$((FAIL+1)); fi
# AGY_SIGNAL must land in the same file, so failures are attributable to a cost.
rm -f "$ULOG"
STUB_MODE=quota AGY_USAGE_LOG="$ULOG" "$DELEGATE" "hi" >/dev/null 2>&1 || true
if grep -q '^AGY_SIGNAL ' "$ULOG" 2>/dev/null; then
  echo "ok: AGY_USAGE_LOG also captures AGY_SIGNAL"; PASS=$((PASS+1));
else echo "FAIL: AGY_SIGNAL not written to AGY_USAGE_LOG"; FAIL=$((FAIL+1)); fi
# Appends across delegations rather than truncating (a session has many).
STUB_MODE=quota AGY_USAGE_LOG="$ULOG" "$DELEGATE" "hi" >/dev/null 2>&1 || true
if [ "$(grep -c '^AGY_SIGNAL ' "$ULOG")" -eq 2 ]; then
  echo "ok: AGY_USAGE_LOG appends, does not truncate"; PASS=$((PASS+1));
else echo "FAIL: AGY_USAGE_LOG truncated a previous entry"; FAIL=$((FAIL+1)); fi
# Measurement must never break the work: an unwritable path is non-fatal.
out=$(STUB_JSON_CAPABLE=1 STUB_MODE=json_ok AGY_USAGE_LOG=/nonexistent-dir/x.log "$DELEGATE" "hi" 2>/dev/null); rc=$?
check "unwritable AGY_USAGE_LOG is non-fatal" 0 "$rc" "" "$out"
# ...and non-fatal is not enough: it must also be SILENT. Redirections apply left to
# right, so `>>"$f" 2>/dev/null` attempts the append while stderr is still real stderr
# and leaks a bash redirection error on every call. Asserting only on the exit code
# misses that entirely — check stderr itself.
err=$(STUB_JSON_CAPABLE=1 STUB_MODE=json_ok AGY_USAGE_LOG=/nonexistent-dir/x.log "$DELEGATE" "hi" 2>&1 >/dev/null)
if printf '%s' "$err" | grep -qiE 'No such file or directory|Permission denied'; then
  echo "FAIL: unwritable AGY_USAGE_LOG leaks a redirection error to stderr"; FAIL=$((FAIL+1));
else echo "ok: unwritable AGY_USAGE_LOG is silent, not just non-fatal"; PASS=$((PASS+1)); fi
# Off by default: no file is created when the option is unset.
rm -f "$ULOG"
STUB_JSON_CAPABLE=1 STUB_MODE=json_ok "$DELEGATE" "hi" >/dev/null 2>&1
if [ ! -e "$ULOG" ]; then echo "ok: usage log off by default"; PASS=$((PASS+1));
else echo "FAIL: usage log written without being configured"; FAIL=$((FAIL+1)); fi
# Plugin option is the documented equivalent of the env var.
rm -f "$ULOG"
STUB_JSON_CAPABLE=1 STUB_MODE=json_ok CLAUDE_PLUGIN_OPTION_USAGE_LOG="$ULOG" "$DELEGATE" "hi" >/dev/null 2>&1
if grep -q '^AGY_USAGE ' "$ULOG" 2>/dev/null; then
  echo "ok: CLAUDE_PLUGIN_OPTION_USAGE_LOG works like AGY_USAGE_LOG"; PASS=$((PASS+1));
else echo "FAIL: plugin option usage_log had no effect"; FAIL=$((FAIL+1)); fi
rm -f "$ULOG"

# agy >= 1.1.3: permissioned tool soft-denied headless -> rc=0 + empty stdout + stderr notice
out=$(STUB_MODE=softdeny "$DELEGATE" "implement it" 2>&1); rc=$?
check "agy soft-deny (no permission) -> exit 15 + signal" 15 "$rc" "PERMISSION_DENIED" "$out"

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

# write-task without --yolo -> warn (workspace untouched; issue #10).
# --mode accept-edits stopped granting headless writes on agy 1.1.3, so it still warns.
# Match the stable part of the sentence, not the whole thing: this string has been
# reworded twice now, and an exact-phrase assertion just breaks on prose edits.
WARN='write grant'
out=$(STUB_MODE=args "$DELEGATE" "implement the parser module" 2>&1); rc=$?
check "write prompt w/o --yolo -> warns" 0 "$rc" "$WARN" "$out"
out=$(STUB_MODE=args "$DELEGATE" --yolo "implement the parser module" 2>&1); rc=$?
if printf '%s' "$out" | grep -qF "$WARN"; then echo "FAIL: warned even with --yolo"; FAIL=$((FAIL+1));
else echo "ok: no write-warning when --yolo is set"; PASS=$((PASS+1)); fi
out=$(STUB_MODE=args "$DELEGATE" --mode accept-edits "implement the parser module" 2>&1); rc=$?
if printf '%s' "$out" | grep -qF "$WARN"; then echo "ok: --mode accept-edits still warns (soft-denied on 1.1.3)"; PASS=$((PASS+1));
else echo "FAIL: no warning with --mode accept-edits (should warn since 1.1.3)"; FAIL=$((FAIL+1)); fi
out=$(STUB_MODE=args "$DELEGATE" "summarize the changelog in 3 bullets" 2>&1); rc=$?
if printf '%s' "$out" | grep -qF "$WARN"; then echo "FAIL: warned for a non-write prompt"; FAIL=$((FAIL+1));
else echo "ok: no write-warning for a read/summary prompt"; PASS=$((PASS+1)); fi
# The warning must NOT claim --yolo is the only way in. Confirmed on agy 1.1.9 by a
# controlled A/B (#37): a permissions.allow write_file(<dir>) rule grants headless writes
# with no flag, and this warning fired immediately before one that succeeded.
out=$(STUB_MODE=args "$DELEGATE" "implement the parser module" 2>&1)
check "write warning names the permissions.allow route" 0 0 "permissions.allow" "$out"
if printf '%s' "$out" | grep -q 'NOT write to your workspace without it'; then
  echo "FAIL: warning still asserts --yolo is required for a write"; FAIL=$((FAIL+1));
else echo "ok: warning no longer claims --yolo is the only write grant"; PASS=$((PASS+1)); fi
# Same correction on the exit-15 path — where someone lands after being denied.
out=$(STUB_MODE=softdeny "$DELEGATE" "implement it" 2>&1); rc=$?
check "exit-15 message offers the narrower grant first" 15 "$rc" "permissions.allow" "$out"

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

# issue #29: token-based gate — substring-anywhere bypasses must be BLOCKED (benign payloads)
printf '%s' '{"tool_input":{"command":"foo # agy-delegate"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks comment-appended wrapper name -> exit 2" 2 "$rc"
printf '%s' '{"tool_input":{"command":"echo `foo` agy-job"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks backtick substitution -> exit 2" 2 "$rc"
printf '%s' '{"tool_input":{"command":"agy-delegate x; foo"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks ; chaining after wrapper -> exit 2" 2 "$rc"
printf '%s' '{"tool_input":{"command":"agy-delegate x && foo"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks && chaining after wrapper -> exit 2" 2 "$rc"
printf '%s' '{"tool_input":{"command":"agy-delegate \"$(foo)\""}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks command substitution in dquotes -> exit 2" 2 "$rc"
printf '%s' '{"tool_input":{"command":"foo bar > baz # agy-job"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks redirection -> exit 2" 2 "$rc"
# ...while legitimate forms still pass, including the review pipeline and quoted metachars
printf '%s' '{"tool_input":{"command":"git diff | agy-delegate --tier pro -"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows git diff | agy-delegate - pipeline -> exit 0" 0 "$rc"
printf '%s' '{"tool_input":{"command":"agy-delegate --dir . \"handle a|b; c and $x\""}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate allows metacharacters INSIDE a quoted prompt -> exit 0" 0 "$rc"
printf '%s' '{"tool_input":{"command":"nc evil 9 | agy-delegate -"}}' | "$GATE" >/dev/null 2>&1; rc=$?
check "gate blocks a non-allowlisted pipeline producer -> exit 2" 2 "$rc"

# --- issue #51: newline handling, and saying WHY ------------------------------
# The gate blocked any unquoted newline and gave the same generic message it gives
# for "you tried to run something else", so a caller could not tell a stray newline
# from a real refusal and retried the same shape. Two changes: surrounding whitespace
# is stripped before scanning, and the reason is printed.
gate_rc()  { printf '%s' "{\"tool_input\":{\"command\":$1}}" | "$GATE" >/dev/null 2>&1; echo $?; }
gate_why() { printf '%s' "{\"tool_input\":{\"command\":$1}}" | "$GATE" 2>&1 >/dev/null; }

# Trailing / leading whitespace is normalisation: bash ignores it, and a newline with
# nothing after it cannot start a second command. This is the case you hit when a
# command is composed programmatically.
check "gate allows a trailing newline" 0 "$(gate_rc '"agy-delegate \"hi\"\n"')" "" ""
check "gate allows a leading newline"  0 "$(gate_rc '"\nagy-delegate \"hi\""')" "" ""
check "gate allows trailing spaces/tabs/newlines" 0 "$(gate_rc '"agy-delegate \"hi\" \t\n\n"')" "" ""

# THE property that must not regress. `agy-delegate\n  "hi"` is TWO commands in bash,
# not a formatting nicety — allowing it would be a bypass, so it stays blocked. This
# is also why the reporter's case 6 does not flip.
check "gate still blocks an INTERNAL newline" 2 "$(gate_rc '"agy-delegate\n  \"hi\""')" "" ""
check "gate still blocks a newline after an unquoted pipe" 2 "$(gate_rc '"git diff |\n  agy-delegate -"')" "" ""
check "gate still blocks a newline that starts another command" 2 "$(gate_rc '"agy-delegate x\nfoo"')" "" ""
# Unchanged from before: quoted newlines and backslash continuations were always fine.
check "gate allows a newline inside quotes" 0 "$(gate_rc '"agy-delegate \"line1\nline2\""')" "" ""
# NB: one backslash before the newline. Two (`\\\\` in JSON) is an escaped literal
# backslash followed by a bare newline — correctly blocked, and an easy test to get wrong.
check "gate allows a backslash continuation" 0 "$(gate_rc '"agy-delegate \\\n  \"hi\""')" "" ""
check "gate blocks an ESCAPED backslash then a bare newline" 2 "$(gate_rc '"agy-delegate \\\\\n  \"hi\""')" "" ""
# Stripping must not rescue an unterminated quote.
check "stripping does not rescue an unbalanced quote" 2 "$(gate_rc '"agy-delegate \"hi\n"')" "" ""

# The reason has to name the cause, or the message is no better than before.
check "reason names the newline"        0 0 "unquoted newline"        "$(gate_why '"agy-delegate\n  \"hi\""')"
check "reason offers the remedy"        0 0 "backslash"               "$(gate_why '"agy-delegate\n  \"hi\""')"
check "reason names a ';' separator"    0 0 "command separator"       "$(gate_why '"agy-delegate x; foo"')"
check "reason names substitution"       0 0 "command substitution"    "$(gate_why '"agy-delegate \"$(foo)\""')"
check "reason names an unbalanced quote" 0 0 "unterminated"           "$(gate_why '"agy-delegate \"hi"')"
check "reason names the wrong first command" 0 0 "not agy-delegate"    "$(gate_why '"somethingelse --flag x"')"
check "reason names the pipe count"     0 0 "at most one"             "$(gate_why '"cat f | agy-delegate - | wc"')"
check "reason names the bad producer"   0 0 "left side of the pipe"   "$(gate_why '"ls | agy-delegate -"')"

# The reason goes into the AGENT'S CONTEXT, and a blocked command routinely carries a
# delegation prompt. It must describe the syntax and never quote ANY of the command back.
#
# The shapes below are the ones that actually reach the token-naming branches. An earlier
# version of this test put the marker after a valid argv[0] and behind a `;` — the scan
# rejected it first, so the branch under test was never executed and the test passed for
# free. Both PR reviewers found the leak the test was supposed to cover (#52).
#
# argv[0] is not a safe exception: head() returns shlex.split(seg)[0], the first shell
# WORD, so a leading quoted string becomes argv[0]. Restricting to "name-shaped" tokens
# does not help either — an API key is name-shaped, which is why nothing is echoed at all.
leak_free() { # $1 = label, $2 = json command, $3 = marker that must not appear
  local why; why="$(gate_why "$2")"
  if printf '%s' "$why" | grep -qF "$3"; then
    echo "FAIL: block reason leaks command text ($1)"; FAIL=$((FAIL+1));
  elif [ -z "$why" ]; then
    echo "FAIL: no reason emitted at all ($1) — the assertion below would pass for free"; FAIL=$((FAIL+1));
  else echo "ok: no command text in the reason ($1)"; PASS=$((PASS+1)); fi
}
leak_free "leading quoted token becomes argv[0]" '"\"SECRETPROMPTMARKER text\" agy-delegate \"hi\""' 'SECRETPROMPTMARKER'
leak_free "right side of a pipe"                 '"git diff | \"SECRETPROMPTMARKER\" agy-delegate -"' 'SECRETPROMPTMARKER'
leak_free "left side of a pipe"                  '"\"SECRETPROMPTMARKER\" | agy-delegate -"'           'SECRETPROMPTMARKER'
leak_free "name-shaped token (an API key is)"    '"sk-ant-oat01-SECRETPROMPTMARKER x"'                 'SECRETPROMPTMARKER'
leak_free "plain wrong command"                  '"SECRETPROMPTMARKER --flag x"'                       'SECRETPROMPTMARKER'

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
for b in agy-delegate agy-job agy-cost-compare agy-doctor cloud-debug agy-trace measure-session agy-media; do
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
out=$(env -u CLAUDE_PLUGIN_ROOT "$BIN/measure-session" 2>&1 | head -1)
case "$out" in *measure-session*) echo "ok: bin/measure-session forwards to the .py"; PASS=$((PASS+1));;
  *) echo "FAIL: bin/measure-session did not forward (got: '$out')"; FAIL=$((FAIL+1));; esac

echo "== doctor.sh tier-model check (agy 1.1.5 slug format) =="
# The stub's `agy models` emits slugs (gemini-3.5-flash); doctor's default tier models are
# display names (Gemini 3.5 Flash (High)). Regression guard: doctor must still recognize them.
out=$(bash "$ROOT/scripts/doctor.sh" 2>&1)
if printf '%s' "$out" | grep -q "tier model not in"; then
  echo "FAIL: doctor falsely warns tier model missing against slug-format agy models"; FAIL=$((FAIL+1));
else echo "ok: doctor recognizes tier models across display-name/slug formats"; PASS=$((PASS+1)); fi
if printf '%s' "$out" | grep -q "tier model present: Gemini 3.5 Flash (High)"; then
  echo "ok: doctor matches default flash tier in slug format"; PASS=$((PASS+1));
else echo "FAIL: doctor did not confirm the default flash tier present"; FAIL=$((FAIL+1)); fi

echo "== doctor.sh agy-version gate (--tier is inert below 1.1.10) =="
# agy ignored --model/--effort in headless `-p` until 1.1.10: the flag was applied after
# model configuration had initialised, so the run silently fell back to the persisted
# default. The wrapper resolves every --tier to --model and always runs -p, so on an
# older agy the routing is inert AND looks like it works — the call succeeds, returns
# sensible text, reports usage. Nothing but a version check can surface that.
ver_doctor() { # $1 = version the stub reports; echoes doctor's output
  local d; d="$TMP/agyver"; mkdir -p "$d"
  { echo '#!/usr/bin/env bash'
    echo "[ \"\$1\" = --version ] && { echo '$1'; exit 0; }"
    echo '[ "$1" = models ] && { printf "%s\n" "Gemini 3.5 Flash (High)" "Gemini 3.5 Flash (Low)" "Gemini 3.1 Pro (High)"; exit 0; }'
    echo 'exit 0'; } > "$d/agy"
  chmod +x "$d/agy"
  PATH="$d:$PATH" bash "$ROOT/scripts/doctor.sh" 2>&1
}
if printf '%s' "$(ver_doctor 1.1.9)" | grep -q 'ignores --model'; then
  echo "ok: doctor warns that --tier is inert on agy 1.1.9"; PASS=$((PASS+1));
else echo "FAIL: no warning on agy 1.1.9 — tier selection is silently doing nothing"; FAIL=$((FAIL+1)); fi
# 1.1.10 is the fix, and a naive string compare puts it BELOW 1.1.9 — the boundary is
# the whole point of the check.
if printf '%s' "$(ver_doctor 1.1.10)" | grep -q 'ignores --model'; then
  echo "FAIL: doctor warns on 1.1.10, which is the version that fixed it"; FAIL=$((FAIL+1));
else echo "ok: no warning on agy 1.1.10 (string compare would have got this wrong)"; PASS=$((PASS+1)); fi
if printf '%s' "$(ver_doctor 1.2.0)" | grep -q 'ignores --model'; then
  echo "FAIL: doctor warns on 1.2.0"; FAIL=$((FAIL+1));
else echo "ok: no warning on a later minor (1.2.0)"; PASS=$((PASS+1)); fi
# An unparseable version must not produce a scary warning on a build we cannot judge.
if printf '%s' "$(ver_doctor dev-local)" | grep -q 'ignores --model'; then
  echo "FAIL: doctor warns on an unparseable version"; FAIL=$((FAIL+1));
else echo "ok: unparseable version is left alone"; PASS=$((PASS+1)); fi
# The gate must not depend on `sort -V`. Where that is missing the command substitution
# comes back empty, the comparison quietly fails, and the warning never fires — a version
# gate that silently does nothing reads as a clean bill of health. Both reviewers on #54
# flagged the dependency; this pins the property rather than the implementation.
# Strip comments first: the replacement explains WHY it avoids `sort -V`, and an
# unstripped grep matches that sentence and reports the dependency it removed.
if sed 's/#.*//' "$ROOT/scripts/doctor.sh" | grep -q 'sort -V'; then
  echo "FAIL: doctor's version gate depends on sort -V (absent on some shells)"; FAIL=$((FAIL+1));
else echo "ok: version gate does not depend on sort -V"; PASS=$((PASS+1)); fi
brk="$TMP/nosort"; mkdir -p "$brk"; printf '#!/bin/sh\nexit 127\n' > "$brk/sort"; chmod +x "$brk/sort"
d="$TMP/agyver"; mkdir -p "$d"
{ echo '#!/usr/bin/env bash'
  echo '[ "$1" = --version ] && { echo 1.1.9; exit 0; }'
  echo '[ "$1" = models ] && { printf "%s\n" "Gemini 3.5 Flash (High)" "Gemini 3.5 Flash (Low)" "Gemini 3.1 Pro (High)"; exit 0; }'
  echo 'exit 0'; } > "$d/agy"
chmod +x "$d/agy"
# Capture, THEN grep. `cmd | grep -q` exits at the first match and closes the pipe, the
# upstream dies of SIGPIPE (141), and `set -o pipefail` (line 8) marks the whole pipeline
# failed — so the assertion reads as "no warning" while the warning is right there. This
# is the 0.21.1 bug, in the file whose tests guard against it.
nosort_out="$(PATH="$brk:$d:$PATH" bash "$ROOT/scripts/doctor.sh" 2>&1)"
if printf '%s' "$nosort_out" | grep -q 'ignores --model'; then
  echo "ok: the warning still fires with sort unusable"; PASS=$((PASS+1));
else echo "FAIL: a broken sort silences the version gate"; FAIL=$((FAIL+1)); fi

echo "== doctor.sh stdio-MCP detection (issue #37 diagnostic) =="
# The hint is diagnostic-only, so getting it wrong fails SILENTLY — it just never
# helps the person it exists for. Pin the two things measured against agy 1.1.9:
# stdio servers carry "command", remote ones carry "serverUrl" (not the
# "url"/"httpUrl" spelling other MCP clients use), and plugin-scoped configs
# count too — agy's own docs list global AND plugins/<name>/mcp_config.json.
mcp_count() { # $1 = config root; echoes "<rc> <count>"
  local n rc
  n="$(AGY_CONFIG_DIR="$1" bash -c '
    source_fn() { sed -n "/^has_stdio_mcp() {/,/^}/p" "$1"; }
    eval "$(source_fn "'"$ROOT"'/scripts/doctor.sh")"
    has_stdio_mcp' 2>/dev/null)"; rc=$?
  printf '%s %s' "$rc" "${n:-0}"
}
MCPDIR="$TMP/mcp"; mkdir -p "$MCPDIR/plugins/p1"
cat > "$MCPDIR/mcp_config.json" <<'JSON'
{"mcpServers":{"a":{"command":"node","args":[]},"b":{"command":"npx"},
               "remote":{"serverUrl":"https://x","authProviderType":"oauth"}}}
JSON
check "stdio counted, serverUrl remotes excluded" "0 2" "$(mcp_count "$MCPDIR")" "" ""
cat > "$MCPDIR/plugins/p1/mcp_config.json" <<'JSON'
{"mcpServers":{"c":{"command":"node"},"d":{"serverUrl":"https://y"}}}
JSON
check "plugin-scoped configs are counted too" "0 3" "$(mcp_count "$MCPDIR")" "" ""
rm -f "$MCPDIR/mcp_config.json" "$MCPDIR/plugins/p1/mcp_config.json"
check "no config at all -> rc 1, no false hint" "1 0" "$(mcp_count "$MCPDIR")" "" ""
printf 'not json' > "$MCPDIR/mcp_config.json"
check "malformed config is skipped, not fatal" "1 0" "$(mcp_count "$MCPDIR")" "" ""

echo "== agy-media.sh (multimodal delegation) =="
MEDIA="$ROOT/scripts/agy-media.sh"
MDIR="$TMP/media"; mkdir -p "$MDIR"
: > "$MDIR/clip.wav"; : > "$MDIR/memo.m4a"; : > "$MDIR/demo.mp4"; : > "$MDIR/notes.txt"
# dry run resolves a delegation with --yolo (needed to read the file) and a transcript path
out=$(AGY_DELEGATE=/nonexistent "$MEDIA" "$MDIR/clip.wav" --print-command 2>/dev/null); rc=$?
check "media dry-run resolves a delegation" 0 "$rc" "agy-delegate" "$out"
check "media passes --yolo (needed to read media)" 0 "$rc" "--yolo" "$out"
check "media requests a timestamped transcript file" 0 "$rc" "clip.transcript.md" "$out"
check "media enforces the digest contract" 0 "$rc" "ONLY a compact digest" "$out"
out=$(AGY_DELEGATE=/nonexistent "$MEDIA" "$MDIR/demo.mp4" --print-command 2>/dev/null); rc=$?
check "media asks for VISUALS on video" 0 "$rc" "VISUALS" "$out"
out=$(AGY_DELEGATE=/nonexistent "$MEDIA" "$MDIR/clip.wav" "the pricing numbers" --print-command 2>/dev/null); rc=$?
check "media threads the focus into the prompt" 0 "$rc" "the pricing numbers" "$out"
# format pre-flight: m4a is mishandled by agy -> exit 5 with a conversion hint
out=$("$MEDIA" "$MDIR/memo.m4a" 2>&1); rc=$?
check "media blocks unsupported .m4a -> exit 5" 5 "$rc" "not reliably supported" "$out"
out=$("$MEDIA" "$MDIR/notes.txt" 2>&1); rc=$?
check "media rejects a non-media extension -> exit 5" 5 "$rc" "unrecognized media extension" "$out"
out=$("$MEDIA" "$MDIR/nope.wav" 2>&1); rc=$?
check "media missing file -> exit 4" 4 "$rc" "file not found" "$out"
out=$("$MEDIA" 2>&1); rc=$?
check "media with no args -> exit 1 (friendly)" 1 "$rc" "no media file given" "$out"

echo "== agy-trace.sh (delegation trajectory reader) =="
TRACE="$ROOT/scripts/agy-trace.sh"
# fixture: a brain dir with one transcript (shape matches agy 1.0.12 / 1.1.8)
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

# --- --audit / --last: verifying what a PLAIN delegation actually did ---------
# agy writes a transcript for every run, not just invoke_subagent spawns, and the
# conversationId is in agy-delegate's AGY_USAGE line — so cost and trajectory join
# 1:1. A delegation can report SUCCESS while individual commands inside it failed
# (observed: 6 non-zero exits under an overall-SUCCESS run), which is exactly what
# the skill's "never trust agy's self-reported GREEN" rule needs surfaced.
mkdir -p "$FIXBRAIN/conv-cmd/.system_generated/logs"
cat > "$FIXBRAIN/conv-cmd/.system_generated/logs/transcript.jsonl" <<'JSONL'
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>build it</USER_REQUEST>"}
{"step_index":1,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","exit_code":0,"content":"The command exited with code 0. Output: ok"}
{"step_index":2,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","exit_code":127,"content":"The command exited with code 127. Output: command not found: pytest"}
{"step_index":3,"source":"MODEL","type":"CODE_ACTION","status":"DONE","content":"wrote app/main.py"}
JSONL
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --audit conv-cmd 2>&1); rc=$?
check "--audit counts step types" 0 "$rc" "RUN_COMMAND            2" "$out"
check "--audit surfaces a failing command inside a 'successful' run" 0 "$rc" "exit=127" "$out"
check "--audit states that command strings are unavailable" 0 "$rc" "command strings are not recorded" "$out"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --audit conv-123 2>&1); rc=$?
check "--audit on a clean run reports no failures" 0 "$rc" "no non-zero exit codes" "$out"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --audit no-such-conv 2>&1); rc=$?
check "--audit unknown conversationId -> exit 2" 2 "$rc" "no transcript" "$out"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --audit 2>&1); rc=$?
check "--audit with no argument -> usage error" 1 "$rc" "needs a conversationId" "$out"
# --last resolves the newest transcript; touch to make the ordering deterministic.
touch "$FIXBRAIN/conv-cmd/.system_generated/logs/transcript.jsonl"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --last 2>&1); rc=$?
check "--last pretty-prints the newest run" 0 "$rc" "CODE_ACTION" "$out"
out=$(AGY_BRAIN_DIR="$FIXBRAIN" "$TRACE" --audit --last 2>&1); rc=$?
check "--audit --last audits the newest run" 0 "$rc" "exit=127" "$out"
out=$(AGY_BRAIN_DIR="$TMP/empty-brain" "$TRACE" --last 2>&1); rc=$?
check "--last with no transcripts -> exit 2" 2 "$rc" "no transcripts" "$out"
# The header must not claim these are subagent-only (it did, incorrectly, until 0.22.0).
if grep -q 'EVERY agy run leaves' "$ROOT/scripts/agy-trace.sh"; then
  echo "ok: agy-trace documents that all delegations leave a transcript"; PASS=$((PASS+1));
else echo "FAIL: agy-trace still scoped to subagents only"; FAIL=$((FAIL+1)); fi

echo "== prices.json / hardcoded-rate drift =="
# agy-cost-compare.sh reads prices.json, but falls back to hardcoded rates when
# prices.json or python3 is missing. Those fallbacks silently went stale when the
# Gemini output rate changed (9.00 -> 7.50), so the script would have quoted the old
# number in exactly the situation where nobody can see where it came from. Assert the
# two stay in step rather than relying on whoever edits prices.json to remember.
out=$(ROOT="$ROOT" python3 - <<'PY' 2>&1
import json, os, re, sys
root = os.environ["ROOT"]
pj = json.load(open(os.path.join(root, "prices.json")))
src = open(os.path.join(root, "scripts", "agy-cost-compare.sh")).read()
want = {
    "CLAUDE_IN_PER_M":  pj["claude_opus"]["in"],
    "CLAUDE_OUT_PER_M": pj["claude_opus"]["out"],
    "GEMINI_IN_PER_M":  pj["gemini_flash"]["in"],
    "GEMINI_OUT_PER_M": pj["gemini_flash"]["out"],
}
bad = []
for var, expected in want.items():
    m = re.search(re.escape(var) + r'="\$\{' + var + r':-\$\{_[A-Z]+:-([0-9.]+)\}\}"', src)
    if not m:
        bad.append(f"{var}: fallback not found (pattern changed?)")
    elif float(m.group(1)) != float(expected):
        bad.append(f"{var}: fallback {m.group(1)} != prices.json {expected}")
print("; ".join(bad) if bad else "IN-SYNC")
PY
)
if [ "$out" = "IN-SYNC" ]; then
  echo "ok: agy-cost-compare fallback rates match prices.json"; PASS=$((PASS+1));
else echo "FAIL: rate drift — $out"; FAIL=$((FAIL+1)); fi

# agy-cost-compare picks the `gemini_flash` key by TIER NAME, not by model, so that key
# must price whatever `model_for_tier()`'s flash default actually resolves to. Repricing
# it for a newer model that is NOT the default silently understates the Gemini side out
# of the box — which is exactly what happened when 3.6's cheaper output landed here while
# the flash tier still pointed at 3.5.
out=$(ROOT="$ROOT" python3 - <<'PY' 2>&1
import json, os, re
root = os.environ["ROOT"]
pj = json.load(open(os.path.join(root, "prices.json")))
src = open(os.path.join(root, "scripts", "agy-delegate.sh")).read()
m = re.search(r'flash\)\s*echo "\$\{CLAUDE_PLUGIN_OPTION_TIER_FLASH:-([^}]*)\}"', src)
if not m:
    print("flash tier default not found (model_for_tier pattern changed?)"); raise SystemExit
default = m.group(1)
flash, f36 = pj["gemini_flash"], pj.get("gemini_flash_36", {})
if "3.6" in default:
    print("OK" if flash == f36 else f"flash tier is {default!r} but gemini_flash {flash} != gemini_flash_36 {f36}")
elif "3.5" in default:
    print("OK" if flash.get("out") == 9.00 else f"flash tier is {default!r} (out 9.00) but gemini_flash.out = {flash.get('out')}")
else:
    print(f"flash tier default {default!r} is neither 3.5 nor 3.6 — reconcile prices.json by hand")
PY
)
if [ "$out" = "OK" ]; then
  echo "ok: prices.json gemini_flash matches the shipped flash tier"; PASS=$((PASS+1));
else echo "FAIL: $out"; FAIL=$((FAIL+1)); fi

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

echo "== CI workflow invariants =="
# These cannot be executed here — they need a GitHub runner — so assert the SHAPE of the
# two expressions that have each been wrong once, in a way that a well-meaning
# simplification would break.
#
# `cancel-in-progress` is evaluated BEFORE any job condition, so a run that will be
# skipped still cancels whatever is running. Naive `true` made the review cancel itself
# when it posted its summary (#42); `comment.user.type != 'Bot'` fixed that but still let
# ANY human comment kill an in-flight review (#52). It needs both guards.
QW="$ROOT/.github/workflows/quorum-review.yml"
CONC="$(sed -n '/^concurrency:/,/^permissions:/p' "$QW")"
if printf '%s' "$CONC" | grep -q "cancel-in-progress: *true"; then
  echo "FAIL: quorum cancel-in-progress is bare true — the review will cancel itself"; FAIL=$((FAIL+1));
else echo "ok: quorum cancel-in-progress is an expression"; PASS=$((PASS+1)); fi
# Cancel ONLY on a push. `cancel-in-progress: false` queues the new run rather than
# discarding it, so nothing else ever needs to cancel — a comment or a dispatch waits its
# turn. This is what makes the expression safe without replicating the job's `if:`.
if printf '%s' "$CONC" | grep -q "github.event_name == 'pull_request'"; then
  echo "ok: cancel-in-progress cancels only on a push"; PASS=$((PASS+1));
else echo "FAIL: cancel-in-progress no longer keys on pull_request alone"; FAIL=$((FAIL+1)); fi
# The design decision, asserted directly: the moment this expression starts reasoning
# about WHO commented or WHAT they said, it is predicting whether the job will run — and
# it was broader than the job's `if:` on both previous attempts (#42, #53), which is how
# a run that gets skipped ends up cancelling a live review.
if printf '%s' "$CONC" | grep -qE 'comment\.(body|user|author_association)'; then
  echo "FAIL: concurrency inspects the comment again — it must not predict the job condition"; FAIL=$((FAIL+1));
else echo "ok: concurrency does not try to predict whether the job will run"; PASS=$((PASS+1)); fi

# The fork guard runs before anything is cloned or any credential is minted.
if [ "$(grep -n 'Refuse a fork' "$QW" | cut -d: -f1)" \
     -lt "$(grep -n 'actions/checkout@' "$QW" | head -1 | cut -d: -f1)" ]; then
  echo "ok: the fork check precedes the checkout"; PASS=$((PASS+1));
else echo "FAIL: a fork could be cloned before it is refused"; FAIL=$((FAIL+1)); fi

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
for b in ("agy-delegate", "agy-job", "agy-cost-compare", "agy-doctor", "cloud-debug", "agy-trace", "measure-session", "agy-media"):
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
