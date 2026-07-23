#!/usr/bin/env bash
#
# PreToolUse(Bash) gate for the `antigravity-delegate` subagent. Claude Code's
# subagent `tools:` field can't scope Bash to one command, so this hook is the ONLY
# thing restricting what that subagent may run — it must allow a Bash call only when
# it invokes the plugin's delegation wrapper (agy-delegate / agy-job) and nothing else.
#
# Hardening (issue #29): the previous version matched the wrapper name as a SUBSTRING
# anywhere in the command, so payloads like `foo ... # agy-delegate` or
# `echo $(...) agy-job` slipped through (arbitrary execution under prompt injection).
# This version instead:
#   * requires the FIRST command token (argv[0], basename, optional .sh) to be exactly
#     agy-delegate / agy-job — a token check, not a substring match;
#   * allows only one pipeline shape, `<git|cat|echo|printf> | agy-delegate|agy-job -`,
#     so `git diff | agy-delegate -` keeps working;
#   * rejects UNQUOTED shell metacharacters bash would act on (`; & | < > ( ) #`,
#     backticks, `$(`), while permitting them INSIDE a quoted prompt (no false
#     positives on legitimate prompts — command substitution inside double quotes is
#     still blocked because bash would expand it);
#   * fails CLOSED (block) if the JSON is unparseable or python3 is unavailable.
#
# Input: hook JSON on stdin, with .tool_input.command holding the bash command.
# Exit: 0 = allow, 2 = block.
#
set -uo pipefail

input="$(cat)"

BLOCK_MSG="[antigravity-delegate] blocked: this subagent may only run agy-delegate / agy-job (optionally as \`<git|cat|echo|printf> | agy-delegate -\`). No other commands, chaining, redirection, substitution, or comments. Delegate file work to agy; verification is the caller's job."

# python3 gives a correct, quote-aware parse. Fail CLOSED if it's missing.
if ! command -v python3 >/dev/null 2>&1; then
  echo "$BLOCK_MSG (python3 unavailable — failing closed)" >&2
  exit 2
fi

if AGY_GATE_INPUT="$input" python3 - <<'PY'
import json, os, shlex, sys

raw = os.environ.get("AGY_GATE_INPUT", "")
try:
    cmd = json.loads(raw).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(2)                      # unparseable payload -> fail closed
if not isinstance(cmd, str) or not cmd.strip():
    sys.exit(2)

WRAPPERS  = {"agy-delegate", "agy-job"}
PRODUCERS = {"git", "cat", "echo", "printf"}

def base(tok):
    b = os.path.basename(tok)
    return b[:-3] if b.endswith(".sh") else b

# Quote-aware scan: split into pipeline segments on UNQUOTED '|', and flag any
# unquoted metacharacter bash would act on (plus command substitution inside "").
def scan(s):
    segs, cur, st, i, n, bad = [], [], "U", 0, len(s), False
    while i < n:
        c = s[i]
        if st == "U":
            if c == "'":  st = "S"; cur.append(c); i += 1; continue
            if c == '"':  st = "D"; cur.append(c); i += 1; continue
            if c == "\\":
                cur.append(c)
                if i + 1 < n: cur.append(s[i + 1]); i += 2; continue
                i += 1; continue
            if c == "|":  segs.append("".join(cur)); cur = []; i += 1; continue
            if c == "`":  bad = True; cur.append(c); i += 1; continue
            if c == "$":
                if i + 1 < n and s[i + 1] == "(": bad = True
                cur.append(c); i += 1; continue
            if c in ";&<>()#\n": bad = True; cur.append(c); i += 1; continue
            cur.append(c); i += 1; continue
        if st == "S":
            cur.append(c)
            if c == "'": st = "U"
            i += 1; continue
        # st == "D"
        cur.append(c)
        if c == '"': st = "U"; i += 1; continue
        if c == "\\":
            if i + 1 < n: cur.append(s[i + 1]); i += 2; continue
            i += 1; continue
        if c == "`": bad = True; i += 1; continue
        if c == "$":
            if i + 1 < n and s[i + 1] == "(": bad = True
            i += 1; continue
        i += 1
    segs.append("".join(cur))
    if st != "U":
        return None, True            # unbalanced quotes -> unsafe
    return segs, bad

segs, bad = scan(cmd)
if segs is None or bad:
    sys.exit(2)

def head(seg):
    try:
        toks = shlex.split(seg)
    except Exception:
        return None
    return toks[0] if toks else None

if len(segs) == 1:
    t = head(segs[0])
    sys.exit(0 if t and base(t) in WRAPPERS else 2)
elif len(segs) == 2:
    lt, rt = head(segs[0]), head(segs[1])
    ok = bool(lt) and base(lt) in PRODUCERS and bool(rt) and base(rt) in WRAPPERS
    sys.exit(0 if ok else 2)
else:
    sys.exit(2)                      # more than one pipe
PY
then
  exit 0
else
  echo "$BLOCK_MSG" >&2
  exit 2
fi
