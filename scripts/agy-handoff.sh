#!/usr/bin/env bash
#
# agy-handoff — hand a WHOLE task to Antigravity (agy / Gemini), verify it by running the
# repository's tests, allow one fix-up, report. The conductor (Claude) reads nothing.
#
# This is the one delegation shape that measured cheaper than Claude Code alone on
# implementation work (bench/PROTOCOL-handoff.md, 8 merged PRs × 2, 2026-09-17): 16/16
# tests passed at 0.58× a solo Opus 5 run per passing task at the pre-registered price
# deck — 0.43× on large tasks (≥700 changed lines), a LOSS on small ones (<100 lines) —
# with the Claude side at 0.16×, and wall-clock 3.6×. A blinded reviewer rated the code
# 0.6 of 5 below the solo run (dead code, duplicated helpers, unasked-for options), about
# 0.2 below the human-merged PR: hand-off output needs the same human review a first
# draft would get. Per-file delegation with the conductor reading and specifying cost
# 1.3–1.7× solo in the same study; asking the executor to review its own diff afterwards
# changed the score by 0.07 and cost $1 a run. So: whole task, tests as the gate, no
# reading, human review after — nothing else.
#
# Usage:
#   agy-handoff [options] "<requirement>"        # or `-` to read the requirement from stdin
# Options:
#   -d, --dir <repo>            repository root (default: .); refused for $HOME and /
#   -t, --tier <flash|pro>      executor tier (default: flash — what the measurement used)
#   -m, --model <exact name>    exact agy model instead of a tier
#       --timeout <dur>         executor timeout for the main delegation (default: 120m)
#       --fixup-timeout <dur>   executor timeout for a fix-up (default: 60m)
#       --verify "<cmd>"        verification command run in <repo> (default: detected from
#                               go.mod / package.json / pyproject.toml / Cargo.toml / Makefile)
#       --verify-timeout <sec>  cap on one verification run (default: 1800)
#       --fixups <n>            fix-up delegations allowed when verification fails (default: 1)
#       --tests <paths>         comma-separated test files that already exist and must pass
#                               UNMODIFIED; a change to any of them fails the hand-off (exit 6)
#       --no-verify             skip verification (report only; not the measured protocol)
#       --allow-dirty           run with uncommitted changes present (default: refuse)
#       --new-project <auto|on|off>  register <repo> with agy first (default: auto = on;
#                               measured on agy 1.2.2: in a directory agy has never seen it
#                               works in its LAST project root instead — 450 s vs 119 s)
#       --background            run detached as an agy-job (prints the job id; collect with
#                               `agy-job status|result <id>`); use it in interactive Claude Code
#                               sessions, where a 20–120 min Bash call gets cut off
#       --json                  machine-readable result on stdout (summary goes to stderr)
#       --print-command         show the plan and the first executor command; run nothing
#   -h, --help
#
# Exit codes: 0 verified | 1 usage/refused | 2 executor failed and nothing verified |
#             4 verification still failing after the fix-ups | 6 a named test file was modified |
#             10 quota | 11 auth | 12 executor timeout (and verification failed) | 13 agy missing
#
# AGY_USAGE / AGY_SIGNAL lines from every delegation pass through on stderr (and into
# $AGY_USAGE_LOG when set), so `measure-session.py` prices a hand-off like any delegation.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELEGATE="${AGY_DELEGATE_BIN:-$HERE/agy-delegate.sh}"
REG="${ANTIGRAVITY_JOBS:-$HOME/.antigravity-jobs}"

usage() { sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }
die() { echo "agy-handoff: $*" >&2; exit 1; }

DIR="."; TIER="flash"; MODEL=""; TIMEOUT="120m"; FIX_TIMEOUT="60m"; VERIFY=""; VERIFY_TIMEOUT=1800
FIXUPS=1; TESTS=""; NO_VERIFY=0; ALLOW_DIRTY=0; NEW_PROJECT="auto"; BACKGROUND=0; JSON=0; PRINT=0; REQ=""
ORIG_ARGS=("$@")
need() { [ $# -ge 2 ] || die "option $1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dir) need "$@"; DIR="$2"; shift 2 ;;
    -t|--tier) need "$@"; TIER="$2"; shift 2 ;;
    -m|--model) need "$@"; MODEL="$2"; shift 2 ;;
    --timeout) need "$@"; TIMEOUT="$2"; shift 2 ;;
    --fixup-timeout) need "$@"; FIX_TIMEOUT="$2"; shift 2 ;;
    --verify) need "$@"; VERIFY="$2"; shift 2 ;;
    --verify-timeout) need "$@"; VERIFY_TIMEOUT="$2"; shift 2 ;;
    --fixups) need "$@"; FIXUPS="$2"; shift 2 ;;
    --tests) need "$@"; TESTS="$2"; shift 2 ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --new-project) need "$@"; NEW_PROJECT="$2"; shift 2 ;;
    --background) BACKGROUND=1; shift ;;
    --json) JSON=1; shift ;;
    --print-command) PRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -) REQ="$(cat)"; shift ;;
    --) shift; [ $# -gt 0 ] && REQ="$1"; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$REQ" ] || die "one requirement only (quote it, or pass - and pipe it in)"; REQ="$1"; shift ;;
  esac
done
printf '%s' "$REQ" | grep -q '[^[:space:]]' || { usage >&2; exit 1; }
case "$FIXUPS" in ''|*[!0-9]*) die "--fixups must be a number" ;; esac
case "$VERIFY_TIMEOUT" in ''|*[!0-9]*) die "--verify-timeout must be seconds" ;; esac
[ -d "$DIR" ] || die "no such directory: $DIR"
DIR="$(cd "$DIR" && pwd -P)"
HOME_P="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
[ "$DIR" != "/" ] && [ "$DIR" != "$HOME_P" ] || die "refusing to hand off $DIR — point --dir at a repository, not your home or /"

# ---- repository state -----------------------------------------------------------
IN_GIT=0
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT=1
  if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then
    die "$DIR has uncommitted changes; the executor's edits would mix with yours. Commit or stash first (a dedicated branch is the measured practice), or pass --allow-dirty."
  fi
else
  echo "agy-handoff: note: $DIR is not a git repository — no change summary, no test-file tamper check" >&2
fi

# ---- verification command ------------------------------------------------------------
detect_verify() {
  if [ -f "$DIR/go.mod" ]; then echo "go build ./... && go vet ./... && go test ./..."
  elif [ -f "$DIR/package.json" ] && grep -q '"test"' "$DIR/package.json" 2>/dev/null; then echo "npm test"
  elif [ -f "$DIR/Cargo.toml" ]; then echo "cargo test"
  elif [ -f "$DIR/pyproject.toml" ] || [ -f "$DIR/pytest.ini" ] || [ -f "$DIR/setup.cfg" ]; then echo "python3 -m pytest -q"
  elif [ -f "$DIR/Makefile" ] && grep -qE '^test:' "$DIR/Makefile" 2>/dev/null; then echo "make test"
  fi
}
if [ "$NO_VERIFY" != "1" ] && [ -z "$VERIFY" ]; then
  VERIFY="$(detect_verify)"
  [ -n "$VERIFY" ] || die "no verification command detected in $DIR (go.mod, package.json test script, Cargo.toml, pyproject.toml, Makefile test) — pass --verify \"<cmd>\", or --no-verify to hand off without the gate the measurement relied on"
fi

# ---- prompts -----------------------------------------------------------------------------
TESTS_LINE=""
[ -n "$TESTS" ] && TESTS_LINE="The test files $TESTS already exist in this repository and must pass UNMODIFIED; do not edit, delete or rename them."
VERIFY_LINE="Before you finish, run: $VERIFY — and fix whatever fails."
[ "$NO_VERIFY" = "1" ] && VERIFY_LINE="Run the repository's own build and tests before you finish and fix whatever fails."
CONTRACT="--- Hand-off contract ---
You are implementing the whole requirement above in the repository at $DIR, on your own. Nobody else will read the code before it is tested.
- Work in that repository only. Read whatever you need; keep to the conventions of the surrounding code; no new dependencies unless the requirement asks for them.
- $TESTS_LINE
- Add nothing the requirement did not ask for: no extra options, no speculative helpers, no dead code. Match import grouping and naming to the package you are in.
- $VERIFY_LINE
- Leave the changes uncommitted in the working tree. Do not create commits, branches or tags.
- Finish with a few lines: what you changed (files), how you verified it, anything you could not do."
PROMPT1="$REQ

$CONTRACT"

DELEGATE_OPTS=(--tier "$TIER" --yolo --dir "$DIR")
[ -n "$MODEL" ] && DELEGATE_OPTS+=(--model "$MODEL")

if [ "$PRINT" = "1" ]; then
  echo "agy-handoff plan"
  echo "  dir:      $DIR"
  echo "  tier:     $TIER${MODEL:+ (model: $MODEL)}"
  echo "  timeout:  $TIMEOUT (fix-up: $FIX_TIMEOUT), fix-ups: $FIXUPS"
  if [ "$NO_VERIFY" = "1" ]; then echo "  verify:   (skipped: --no-verify)"; else echo "  verify:   $VERIFY  (timeout ${VERIFY_TIMEOUT}s)"; fi
  [ -n "$TESTS" ] && echo "  tests:    $TESTS (must pass unmodified)"
  echo "  register: agy --new-project (${NEW_PROJECT})"
  echo "  step 1:   agy-delegate ${DELEGATE_OPTS[*]} --timeout $TIMEOUT - <<'REQ' … REQ"
  echo "  step 2:   $VERIFY"
  echo "  step 3:   on failure, up to $FIXUPS fix-up delegation(s) quoting the failing output, then verify again"
  echo "--- prompt (step 1) ---"
  printf '%s\n' "$PROMPT1"
  exit 0
fi

# ---- background: detach as an agy-job so status/result work unchanged --------------------------
if [ "$BACKGROUND" = "1" ]; then
  id="$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}"; jd="$REG/$id"; mkdir -p "$jd"
  { echo "id=$id"; echo "cwd=$PWD"; echo "started=$(date -u +%FT%TZ 2>/dev/null || date)";
    echo "task=handoff: $(printf '%s' "$REQ" | tr '\n' ' ' | cut -c1-190)"; } > "$jd/meta"
  args=(); for a in "${ORIG_ARGS[@]}"; do [ "$a" = "--background" ] || args+=("$a"); done
  printf '%s' "$REQ" > "$jd/requirement"
  # the requirement travels by file, so a `-` (stdin) invocation survives the detach
  clean=(); skip=0; for a in "${args[@]}"; do
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$a" in -) continue ;; *) clean+=("$a") ;; esac
  done
  ( nohup "${BASH_SOURCE[0]}" "${clean[@]}" - < "$jd/requirement" >"$jd/out" 2>"$jd/err"; echo $? >"$jd/rc" ) >/dev/null 2>&1 &
  echo $! > "$jd/pid"; disown 2>/dev/null || true
  echo "$id"
  exit 0
fi

# ---- helpers ------------------------------------------------------------------------------
now_s() { date +%s; }
T0="$(now_s)"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
USAGE_ALL="$TMPD/usage"; : > "$USAGE_ALL"
TIMEOUT_BIN=""; command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN=timeout
[ -z "$TIMEOUT_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN=gtimeout

delegate() { # $1 = prompt  $2 = timeout  $3 = out file ; returns the wrapper's rc; stderr passes through
  local prompt="$1" to="$2" out="$3" err="$TMPD/err.$$.$RANDOM" rc
  printf '%s' "$prompt" | "$DELEGATE" "${DELEGATE_OPTS[@]}" --timeout "$to" - >"$out" 2>"$err"; rc=$?
  cat "$err" >&2
  grep -E '^AGY_(USAGE|SIGNAL) ' "$err" >> "$USAGE_ALL" 2>/dev/null || true
  return $rc
}
verify() { # $1 = out file ; returns the command's rc
  local out="$1" rc
  if [ -n "$TIMEOUT_BIN" ]; then
    ( cd "$DIR" && "$TIMEOUT_BIN" --kill-after=30 "$VERIFY_TIMEOUT" bash -c "$VERIFY" ) >"$out" 2>&1; rc=$?
  else
    ( cd "$DIR" && bash -c "$VERIFY" ) >"$out" 2>&1; rc=$?
  fi
  return $rc
}
tail_for_prompt() { tail -n 150 "$1" | cut -c1-400 | head -c 12000; }

# ---- register the repository with agy (zero-turn probe) -----------------------------------
if [ "$NEW_PROJECT" != "off" ] && command -v agy >/dev/null 2>&1; then
  ( cd "$DIR" && agy --new-project --output-format json -p /model </dev/null >/dev/null 2>&1 ) || true
fi

# ---- step 1: the whole task ----------------------------------------------------------
DELEGATIONS=0; FIXUPS_DONE=0; LAST_OUT="$TMPD/out1"
delegate "$PROMPT1" "$TIMEOUT" "$LAST_OUT"; RC1=$?
DELEGATIONS=$((DELEGATIONS+1))
case "$RC1" in
  10|11|13) echo "agy-handoff: executor unavailable (agy-delegate exit $RC1); nothing verified" >&2; exit "$RC1" ;;
esac
[ "$RC1" -eq 0 ] || echo "agy-handoff: note: the executor returned exit $RC1; verifying whatever landed" >&2

# ---- step 2/3: verify, fix up, verify ---------------------------------------------------
VRC=0; VOUT="$TMPD/verify"
if [ "$NO_VERIFY" = "1" ]; then
  : > "$VOUT"
else
  verify "$VOUT"; VRC=$?
  while [ "$VRC" -ne 0 ] && [ "$FIXUPS_DONE" -lt "$FIXUPS" ]; do
    FIXUPS_DONE=$((FIXUPS_DONE+1))
    FIXPROMPT="The verification command below fails in the repository at $DIR after your change. Fix it. Do not modify test files. Verbatim output (last lines):

\$ $VERIFY
$(tail_for_prompt "$VOUT")

Original requirement, for reference:
$REQ

$CONTRACT"
    LAST_OUT="$TMPD/out.fix$FIXUPS_DONE"
    delegate "$FIXPROMPT" "$FIX_TIMEOUT" "$LAST_OUT"; RCF=$?
    DELEGATIONS=$((DELEGATIONS+1))
    case "$RCF" in 10|11|13) echo "agy-handoff: executor unavailable during fix-up (exit $RCF)" >&2; exit "$RCF" ;; esac
    verify "$VOUT"; VRC=$?
  done
fi

# ---- test-file tamper check -------------------------------------------------------------
TAMPERED=""
if [ -n "$TESTS" ] && [ "$IN_GIT" = "1" ]; then
  IFS=',' read -r -a tarr <<< "$TESTS"
  for t in "${tarr[@]}"; do
    t="${t## }"; t="${t%% }"; [ -n "$t" ] || continue
    if [ -n "$(git -C "$DIR" status --porcelain -- "$t" 2>/dev/null)" ]; then TAMPERED="${TAMPERED:+$TAMPERED,}$t"; fi
  done
fi

# ---- report -----------------------------------------------------------------------------
WALL=$(( $(now_s) - T0 ))
CHANGED=0; UNTRACKED=0; DIFFSTAT=""
if [ "$IN_GIT" = "1" ]; then
  CHANGED="$(git -C "$DIR" status --porcelain 2>/dev/null | grep -c '' || true)"
  UNTRACKED="$(git -C "$DIR" status --porcelain 2>/dev/null | grep -c '^??' || true)"
  DIFFSTAT="$(git -C "$DIR" diff --shortstat 2>/dev/null | sed 's/^ *//')"
fi
STATUS="pass"; EXIT=0
if [ -n "$TAMPERED" ]; then STATUS="tests_modified"; EXIT=6
elif [ "$NO_VERIFY" = "1" ]; then STATUS="unverified"; EXIT=0; [ "$RC1" -eq 0 ] || { STATUS="executor_failed"; EXIT=2; }
elif [ "$VRC" -ne 0 ]; then STATUS="fail"; EXIT=4; [ "$RC1" -eq 12 ] && EXIT=12; [ "$RC1" -eq 2 ] || [ "$RC1" -eq 3 ] && [ "$DELEGATIONS" -eq 1 ] && EXIT=2
fi
LAST_LINES="$(grep -v '^[[:space:]]*$' "$LAST_OUT" 2>/dev/null | tail -n 8)"
USAGE_JSON="{}"
if command -v python3 >/dev/null 2>&1; then
  USAGE_JSON="$(python3 - "$USAGE_ALL" <<'PY' 2>/dev/null || echo '{}'
import json, sys
tot = {"calls": 0, "input": 0, "output": 0, "cache_read": 0, "errors": 0}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if not line.startswith("AGY_USAGE "):
        continue
    try:
        u = json.loads(line[10:])
    except Exception:
        continue
    tot["calls"] += 1
    if str(u.get("status", "")).upper() != "SUCCESS":
        tot["errors"] += 1
    us = u.get("usage") or {}
    for k in ("input", "output", "cache_read"):
        tot[k] += int(us.get(k) or 0)
print(json.dumps(tot))
PY
)"
fi

summary() {
  echo "agy-handoff: $(echo "$STATUS" | tr '[:lower:]' '[:upper:]')  ($DELEGATIONS delegation(s), $FIXUPS_DONE fix-up(s), $((WALL/60)) min)"
  echo "  dir:      $DIR   tier: $TIER${MODEL:+ ($MODEL)}"
  if [ "$NO_VERIFY" = "1" ]; then echo "  verify:   skipped"; else echo "  verify:   $VERIFY -> exit $VRC"; fi
  [ "$IN_GIT" = "1" ] && echo "  changed:  $CHANGED path(s) (${DIFFSTAT:-no tracked diff}; $UNTRACKED untracked)"
  [ -n "$TAMPERED" ] && echo "  TEST FILES MODIFIED: $TAMPERED"
  [ "$USAGE_JSON" != "{}" ] && echo "  executor: $USAGE_JSON"
  if [ -n "$LAST_LINES" ]; then echo "  executor said:"; printf '%s\n' "$LAST_LINES" | sed 's/^/    | /'; fi
  if [ "$VRC" -ne 0 ] && [ "$NO_VERIFY" != "1" ]; then echo "  last verification output:"; tail -n 25 "$VOUT" | sed 's/^/    | /'; fi
  case "$STATUS" in
    pass) echo "  next: review the diff as you would a first draft (git diff), then commit on a branch. The measurement's reviewer docked hand-off code for dead code, duplicated helpers and unasked-for options — look for those." ;;
    fail) echo "  next: the tests are red after $FIXUPS_DONE fix-up(s). Read the failure above and decide: one more hand-off with a sharper requirement, or take over." ;;
    tests_modified) echo "  next: a named test file changed — reject the result (git checkout -- <tests>) and rerun with a requirement that says why the test is right." ;;
  esac
}
if [ "$JSON" = "1" ]; then
  summary >&2
  python3 - "$STATUS" "$EXIT" "$DIR" "$TIER" "$MODEL" "$VERIFY" "$VRC" "$DELEGATIONS" "$FIXUPS_DONE" "$WALL" "$CHANGED" "$UNTRACKED" "$DIFFSTAT" "$TAMPERED" "$USAGE_JSON" "$LAST_OUT" <<'PY' 2>/dev/null || printf '{"status":"%s","exit":%s}\n' "$STATUS" "$EXIT"
import json, sys
a = sys.argv[1:]
last = ""
try:
    last = open(a[15], encoding="utf-8", errors="replace").read()[-4000:]
except Exception:
    pass
print(json.dumps({"schema": "agy-handoff/1", "status": a[0], "exit": int(a[1]), "dir": a[2], "tier": a[3], "model": a[4] or None,
                  "verify": a[5], "verify_rc": int(a[6]), "delegations": int(a[7]), "fixups": int(a[8]), "wall_s": int(a[9]),
                  "changed_paths": int(a[10]), "untracked": int(a[11]), "diffstat": a[12], "tests_modified": [t for t in a[13].split(",") if t],
                  "executor_usage": json.loads(a[14] or "{}"), "executor_said": last}, ensure_ascii=False))
PY
else
  summary
fi
exit "$EXIT"
