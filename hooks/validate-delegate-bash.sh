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
#   * allows NO pipeline at all. A producer allowlist was the second half of the #29
#     hardening and it is what GHSA-hwv2-vjgj-8rcv broke, twice over: `git` with
#     unrestricted arguments is a living-off-the-land binary (`git -c alias.x='!cmd' x`,
#     `--exec-path=`, `-c core.pager=` all execute arbitrary commands, all measured), and
#     `cat`/`echo`/`printf` feeding `agy-delegate -` reads any file or `$VAR` and ships it
#     to the external model. Allowing a command by NAME while ignoring its arguments is
#     not an identity check. Nothing needed the pipeline: this subagent's own contract
#     says the gate "blocks every Bash command except the delegation wrapper" and shows
#     only `agy-delegate [options] "<task>"`, and the documented
#     `git diff | agy-delegate --tier pro -` in commands/review.md runs as the MAIN
#     Claude, which this hook does not gate;
#   * rejects UNQUOTED shell metacharacters bash would act on (`; & | < > ( ) #`,
#     backticks, `$(`, and a NEWLINE — it separates commands just like `;`), while
#     permitting them INSIDE a quoted prompt (no false positives on legitimate
#     prompts — command substitution inside double quotes is still blocked because
#     bash would expand it). Leading/trailing whitespace is stripped first, so a
#     trailing newline is fine; an internal one is two commands and stays blocked;
#   * fails CLOSED (block) if the JSON is unparseable or python3 is unavailable.
#
# On a block it prints the SPECIFIC reason to stderr before the generic message
# (issue #51). Claude Code feeds PreToolUse stderr back to the agent, so the caller
# can tell "you left a newline in" apart from "you tried to run something else" —
# previously both produced the same string and the agent retried the same shape.
#
# Input: hook JSON on stdin, with .tool_input.command holding the bash command.
# Exit: 0 = allow, 2 = block.
#
set -uo pipefail

input="$(cat)"

BLOCK_MSG="[antigravity-delegate] blocked: this subagent may only run agy-delegate / agy-job / agy-handoff, as a BARE name with no path and no pipeline. No other commands, pipes, chaining, redirection, substitution, comments, or unquoted newlines. To give agy a repository, pass --dir <repo-root> rather than piping content in. Delegate file work to agy; verification is the caller's job."

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

# Leading/trailing whitespace is normalised away BEFORE scanning (issue #51). bash
# ignores it, so this cannot change what the command does — and a newline with
# nothing after it cannot begin a second command. Internal newlines are untouched
# and still rejected below. An unterminated quote still fails the state check:
# `agy-delegate "hi\n` strips to `agy-delegate "hi`, which is still unbalanced.
cmd = cmd.strip()

WRAPPERS = {"agy-delegate", "agy-job", "agy-handoff"}

# Say WHY, on stderr, so the caller can self-correct (issue #51). Claude Code feeds
# PreToolUse stderr back to the agent, which is the same path BLOCK_MSG already takes.
#
# NEVER include the command text. This lands in the agent's context and the blocked
# command routinely carries a delegation prompt the caller would not want quoted back;
# a character name and an offset are enough to fix it. `argv[0]` is the exception —
# it is a command name, not content, and naming it is most of the diagnostic value.
def deny(reason):
    sys.stderr.write("[antigravity-delegate] reason: %s\n" % reason)
    sys.exit(2)

CHAR_NAMES = {";": "';' (command separator)", "&": "'&' (background / chaining)",
              "<": "'<' (redirection)",       ">": "'>' (redirection)",
              "(": "'(' (subshell)",          ")": "')' (subshell)",
              "#": "'#' (comment)"}

# A bare NAME, never a path. This used to be os.path.basename(), which accepted any
# directory: `./agy-delegate` in a cloned repository passed the gate and ran THAT file.
# Untrusted repository content is the exact prompt-injection source SECURITY.md names,
# so the one control it names was defeated by the checkout it was meant to survive.
#
# Nothing needs a path. agents/, commands/ and skills/ have invoked these by bare name
# since 0.14.0 — the plugin puts bin/ on the Bash tool PATH because $CLAUDE_PLUGIN_ROOT
# is not exported to model-run Bash (issue #11). A bare name resolves through PATH,
# which the working directory is not on; a path resolves through the working directory,
# which an attacker controls.
#
# Returns None for anything path-shaped, which every caller treats as "not allowed".
def base(tok):
    if "/" in tok or "\\" in tok:     # backslash too: Git Bash / MSYS accept `.\name`
        return None
    return tok[:-3] if tok.endswith(".sh") else tok

# Quote-aware scan: split into pipeline segments on UNQUOTED '|', and flag any
# unquoted metacharacter bash would act on (plus command substitution inside "").
def scan(s):
    # `bad` carries the REASON (a string) rather than a bool — the gate already knew
    # why it was rejecting and used to throw that away, which made a stray newline
    # indistinguishable from "you tried to run something else" (issue #51).
    segs, cur, st, i, n, bad = [], [], "U", 0, len(s), None
    def flag(what, pos, hint=""):
        # First reason wins; position first so the sentence reads in order.
        return bad or "%s at character %d.%s" % (what, pos + 1, hint)
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
            if c == "`":  bad = flag("backtick command substitution", i); cur.append(c); i += 1; continue
            if c == "$":
                if i + 1 < n and s[i + 1] == "(": bad = flag("`$(` command substitution", i)
                cur.append(c); i += 1; continue
            if c == "\n":
                bad = flag("an unquoted newline", i,
                           " bash treats it as a command separator, so this is two commands."
                           " Quote the argument, or end the line with a backslash to continue it.")
                cur.append(c); i += 1; continue
            if c in ";&<>()#": bad = flag("unquoted %s" % CHAR_NAMES[c], i); cur.append(c); i += 1; continue
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
        if c == "`": bad = flag("backtick command substitution inside double quotes "
                                "(bash still expands it)", i); i += 1; continue
        if c == "$":
            if i + 1 < n and s[i + 1] == "(":
                bad = flag("`$(` command substitution inside double quotes "
                           "(bash still expands it)", i)
            i += 1; continue
        i += 1
    segs.append("".join(cur))
    if st != "U":
        return None, ("an unterminated %s quote" %
                      ("single" if st == "S" else "double"))
    return segs, bad

segs, bad = scan(cmd)
if segs is None or bad:
    deny(bad)

def head(seg):
    try:
        toks = shlex.split(seg)
    except Exception:
        return None
    return toks[0] if toks else None

if len(segs) != 1:
    deny("a pipeline (%d pipe%s). No command may feed the wrapper: `git` with arbitrary "
         "arguments runs arbitrary commands, and `cat`/`echo`/`printf` turn the wrapper "
         "into a way to send any file or environment variable to the external model. "
         "Pass `--dir <repo-root>` and let agy read the repository itself."
         % (len(segs) - 1, "" if len(segs) == 2 else "s"))

t = head(segs[0])
if not t:
    deny("the command could not be tokenised")
if base(t) not in WRAPPERS:
    deny("the first command is not agy-delegate, agy-job or agy-handoff")
sys.exit(0)
PY
then
  exit 0
else
  echo "$BLOCK_MSG" >&2
  exit 2
fi
