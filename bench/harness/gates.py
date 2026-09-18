"""Verification-only shell policy shared by every benchmark arm.

`decide(command, plugin=False)` answers allow/block for one Bash tool call. The same
policy runs in every arm, so the arms differ only in whether the plugin is loaded (which
adds the wrapper heads), whether Edit/Write exist, the prompt appendix and the conductor
model. The scanner is quote-aware: metacharacters inside a quoted prompt are data, the
same ones outside are shell. It is deliberately strict — a legitimate command that trips
it is recorded as a denial in run.json, which is visible; a write that slips through is
not, and would put "Claude wrote the code itself" inside a hybrid number.

Rules (see bench/policy/bash-gate-rules.json for the lists):
  * segments split on && || ; | |& and newlines; every segment must pass;
  * unquoted redirections are blocked except fd dups (2>&1, >&2, 2>&-) and /dev/null
    targets; heredocs, here-strings, process substitution and >| are blocked;
  * backticks are blocked; $(...) is allowed only if the inner command passes too;
    (...) subshells likewise; { ...; } brace groups are blocked; a lone & is blocked;
  * every segment head must be a listed head; leading VAR=value assignments only for
    listed names; timeout/time/command wrappers recurse into the wrapped command;
  * per-head argument rules keep go/gofmt/git/find/rg/sort/tree/uniq from writing or
    executing (go run, gofmt -w, git apply, git diff --output, find -exec, ...);
  * agy-delegate / agy-job / agy-trace are allowed with any arguments when `plugin`
    is true (the wrapper is the delegation path); bare `agy` is always blocked so the
    usage log stays complete.
"""
from __future__ import annotations

import json
import os
import re
import shlex
from dataclasses import dataclass, field
from typing import List, Optional

RULES_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          "policy", "bash-gate-rules.json")

_RULES: Optional[dict] = None


def rules() -> dict:
    global _RULES
    if _RULES is None:
        with open(RULES_PATH, encoding="utf-8") as fh:
            _RULES = json.load(fh)
    return _RULES


class Block(Exception):
    """Raised with the specific reason a command is refused."""


@dataclass
class Decision:
    allow: bool
    reason: str
    heads: List[str] = field(default_factory=list)


# ---------------------------------------------------------------- scanner ---

def _match_paren(cmd: str, i: int) -> int:
    """Index of the ')' matching the '(' at cmd[i], honouring quotes and nesting."""
    depth = 0
    in_s = in_d = False
    j = i
    n = len(cmd)
    while j < n:
        c = cmd[j]
        if in_s:
            if c == "'":
                in_s = False
        elif in_d:
            if c == "\\" and j + 1 < n:
                j += 1
            elif c == '"':
                in_d = False
        else:
            if c == "\\" and j + 1 < n:
                j += 1
            elif c == "'":
                in_s = True
            elif c == '"':
                in_d = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return j
        j += 1
    raise Block("unbalanced parenthesis")


_REDIR_OPS = ("&>>", "&>", ">>", ">&", ">|", ">", "<<<", "<<", "<&", "<>", "<")


def _read_target(cmd: str, i: int) -> (str, int):
    """Read a redirection target starting at cmd[i] (after optional spaces)."""
    n = len(cmd)
    while i < n and cmd[i] in " \t":
        i += 1
    if i >= n:
        raise Block("redirection without a target")
    if cmd[i] == "(":
        raise Block("process substitution")
    out = []
    quote = None
    while i < n:
        c = cmd[i]
        if quote:
            if c == quote:
                quote = None
            else:
                out.append(c)
        elif c in "'\"":
            quote = c
        elif c in " \t\n;|&<>()":
            break
        elif c == "\\" and i + 1 < n:
            out.append(cmd[i + 1])
            i += 1
        else:
            out.append(c)
        i += 1
    if quote:
        raise Block("unterminated quote in redirection target")
    return "".join(out), i


def _check_redirection(op: str, target: str) -> None:
    if op in ("<<", "<<<", "<>", ">|"):
        raise Block("heredoc / here-string / read-write redirection")
    if op in (">&", "<&"):
        if target.isdigit() or target == "-" or target == "/dev/null":
            return
        raise Block("redirection to %s" % target)
    if target == "/dev/null":
        return
    raise Block("redirection to %s" % target)


def _segments(cmd: str, plugin: bool, heads: List[str], depth: int = 0) -> None:
    """Split cmd into segments, check each; raises Block on the first violation."""
    if depth > 8:
        raise Block("nesting too deep")
    segs: List[str] = []
    cur: List[str] = []
    in_s = in_d = False
    i = 0
    n = len(cmd)

    def flush():
        text = "".join(cur).strip()
        cur.clear()
        if text:
            segs.append(text)

    def at_token_start() -> bool:
        return not cur or cur[-1] in " \t\n"

    while i < n:
        c = cmd[i]
        nxt = cmd[i + 1] if i + 1 < n else ""
        if in_s:
            cur.append(c)
            if c == "'":
                in_s = False
            i += 1
            continue
        if in_d:
            if c == "\\" and i + 1 < n:
                cur.append(c); cur.append(nxt); i += 2; continue
            if c == '"':
                in_d = False; cur.append(c); i += 1; continue
            if c == "`":
                raise Block("backtick command substitution")
            if c == "$" and nxt == "(":
                if cmd[i + 2:i + 3] == "(":
                    j = _match_paren(cmd, i + 1)
                    cur.append("0"); i = j + 1; continue
                j = _match_paren(cmd, i + 1)
                _segments(cmd[i + 2:j], plugin, heads, depth + 1)
                cur.append("SUBST"); i = j + 1; continue
            cur.append(c); i += 1; continue
        # outside quotes
        if c == "\\" and i + 1 < n:
            cur.append(c); cur.append(nxt); i += 2; continue
        if c == "'":
            in_s = True; cur.append(c); i += 1; continue
        if c == '"':
            in_d = True; cur.append(c); i += 1; continue
        if c == "`":
            raise Block("backtick command substitution")
        if c == "#" and at_token_start():
            while i < n and cmd[i] != "\n":
                i += 1
            continue
        if c == "$" and nxt == "(":
            if cmd[i + 2:i + 3] == "(":
                j = _match_paren(cmd, i + 1)
                cur.append("0"); i = j + 1; continue
            j = _match_paren(cmd, i + 1)
            _segments(cmd[i + 2:j], plugin, heads, depth + 1)
            cur.append("SUBST"); i = j + 1; continue
        if c == "(":
            j = _match_paren(cmd, i)
            _segments(cmd[i + 1:j], plugin, heads, depth + 1)
            flush()
            i = j + 1
            continue
        if c == ")":
            raise Block("unbalanced parenthesis")
        if c == "{" and at_token_start() and nxt in " \t\n":
            raise Block("brace group")
        if c in "<>" or (c == "&" and nxt == ">"):
            # optional fd prefix: trailing digits of cur that form a standalone token
            k = len(cur)
            while k > 0 and cur[k - 1].isdigit():
                k -= 1
            if k < len(cur) and (k == 0 or cur[k - 1] in " \t"):
                del cur[k:]
            op = next(o for o in _REDIR_OPS if cmd.startswith(o, i))
            target, i = _read_target(cmd, i + len(op))
            _check_redirection(op, target)
            cur.append(" ")
            continue
        if c == "&":
            if nxt == "&":
                flush(); i += 2; continue
            raise Block("background job (&)")
        if c == "|":
            flush()
            i += 2 if nxt in "|&" else 1
            continue
        if c == ";" or c == "\n":
            flush(); i += 1; continue
        cur.append(c)
        i += 1
    if in_s or in_d:
        raise Block("unterminated quote")
    flush()
    if not segs and depth == 0:
        raise Block("empty command")
    for seg in segs:
        _analyze(seg, plugin, heads)


# ---------------------------------------------------------------- segments --

def _flag_name(tok: str) -> str:
    return tok.split("=", 1)[0]


def _analyze(seg: str, plugin: bool, heads: List[str]) -> None:
    try:
        toks = shlex.split(seg, posix=True)
    except ValueError as e:
        raise Block("unparseable segment: %s" % e)
    r = rules()
    # leading VAR=value assignments
    while toks and "=" in toks[0] and not toks[0].startswith("-") and toks[0].split("=", 1)[0].isidentifier():
        name = toks[0].split("=", 1)[0]
        if name not in r["env_assignments"]:
            raise Block("environment assignment %s is not allowed" % name)
        toks = toks[1:]
    if not toks:
        return
    head = toks[0]
    base = os.path.basename(head)
    if base.endswith(".sh"):
        base = base[:-3]
    if base in r["plugin_heads"]:
        if not plugin:
            raise Block("%s is not available in this arm" % base)
        heads.append(base)
        return
    if head == "agy":
        raise Block("call agy through agy-delegate, never directly")
    if base not in r["heads"]:
        raise Block("'%s' is not a verification command" % base)
    if os.environ.get("BENCH_POLICY") == "strict" and base in r.get("strict_blocked_heads", []):
        raise Block("'%s' is not available in the hand-off arm (build/test only)" % base)
    heads.append(base)
    # wrappers recurse
    if base == "timeout":
        rest = toks[1:]
        vflags = set(r["timeout"]["value_flags"])
        while rest and rest[0].startswith("-"):
            f = rest[0]
            rest = rest[2:] if f in vflags and "=" not in f else rest[1:]
        if not rest:
            raise Block("timeout without a duration")
        rest = rest[1:]  # the duration
        if not rest:
            raise Block("timeout without a command")
        _analyze(shlex.join(rest), plugin, heads)
        return
    if base == "time":
        rest = [t for t in toks[1:] if not t.startswith("-")] if toks[1:2] and toks[1].startswith("-") else toks[1:]
        if not rest:
            raise Block("time without a command")
        _analyze(shlex.join(rest), plugin, heads)
        return
    if base == "command":
        rest = toks[1:]
        if rest and rest[0] in ("-v", "-V"):
            return
        if not rest:
            return
        _analyze(shlex.join(rest), plugin, heads)
        return
    if base == "set":
        for t in toks[1:]:
            if t not in r["set_flags"]:
                raise Block("set %s" % t)
        return
    checker = _HEAD_RULES.get(base)
    if checker:
        checker(toks, r)


def _rule_go(toks: List[str], r: dict) -> None:
    g = r["go"]
    args = toks[1:]
    if args[:1] == ["-C"]:
        args = args[2:]
    if not args:
        raise Block("bare go")
    sub = args[0]
    if sub not in g["subcommands"]:
        raise Block("go %s is not a verification subcommand" % sub)
    rest = args[1:]
    if sub == "mod":
        if not rest or rest[0] not in g["mod_subcommands"]:
            raise Block("go mod %s" % (rest[0] if rest else ""))
        rest = rest[1:]
    i = 0
    while i < len(rest):
        t = rest[i]
        if t.startswith("-"):
            name = _flag_name(t).lstrip("-")
            if name == "o":
                val = t.split("=", 1)[1] if "=" in t else (rest[i + 1] if i + 1 < len(rest) else "")
                if val not in g["o_allowed_values"]:
                    raise Block("go -o %s writes a file" % (val or "?"))
                if "=" not in t:
                    i += 1
            elif name in g["blocked_flags"]:
                raise Block("go -%s" % name)
        i += 1


def _rule_gofmt(toks: List[str], r: dict) -> None:
    for t in toks[1:]:
        if t.startswith("-") and _flag_name(t).lstrip("-") in r["gofmt"]["blocked_flags"]:
            raise Block("gofmt -w writes files")


def _rule_git(toks: List[str], r: dict) -> None:
    g = r["git"]
    args = toks[1:]
    i = 0
    while i < len(args) and args[i].startswith("-"):
        opt = args[i]
        if opt == "-C":
            i += 2
            continue
        if opt in g["global_opts_allowed"]:
            i += 1
            continue
        raise Block("git global option %s" % opt)
    if i >= len(args):
        raise Block("bare git")
    sub = args[i]
    rest = args[i + 1:]
    if sub not in g["subcommands"]:
        raise Block("git %s is not read-only" % sub)
    for t in rest:
        if t.startswith("-") and _flag_name(t) in g["blocked_flags"]:
            raise Block("git %s %s" % (sub, _flag_name(t)))
    if sub == "branch":
        for t in rest:
            if t not in g["branch_allowed_flags"]:
                raise Block("git branch %s" % t)


def _rule_blocked_flags(key: str):
    def check(toks: List[str], r: dict) -> None:
        blocked = set(r[key]["blocked_flags"])
        for t in toks[1:]:
            if t.startswith("-") and (_flag_name(t) in blocked or t in blocked):
                raise Block("%s %s" % (key, _flag_name(t)))
    return check


_SED_SCRIPT_RE = re.compile(r"^(?:[0-9$,]+|/(?:[^/\\]|\\.)*/(?:,(?:[0-9$]+|/(?:[^/\\]|\\.)*/))?)?p$")


def _rule_sed(toks: List[str], r: dict) -> None:
    """Read-only sed only: -n plus print scripts (`1,60p`, `/a/,/b/p`); no -i, no w/e/s."""
    flags = [t for t in toks[1:] if t.startswith("-") and t != "-"]
    args = [t for t in toks[1:] if not t.startswith("-") or t == "-"]
    for f in flags:
        if f not in ("-n", "-E", "-r", "--quiet", "--silent", "-ne", "-nE", "-En"):
            raise Block("sed %s" % f)
    if not any(f in ("-n", "-ne", "-nE", "-En", "--quiet", "--silent") for f in flags):
        raise Block("sed without -n")
    if not args:
        raise Block("sed without a script")
    script = args[0]
    for part in script.split(";"):
        if not _SED_SCRIPT_RE.match(part.strip()):
            raise Block("sed script %r is not a plain print" % part)


def _rule_uniq(toks: List[str], r: dict) -> None:
    pos = [t for t in toks[1:] if not t.startswith("-")]
    if len(pos) > r["uniq"]["max_positionals"]:
        raise Block("uniq with an output file")


_HEAD_RULES = {
    "go": _rule_go,
    "gofmt": _rule_gofmt,
    "git": _rule_git,
    "find": _rule_blocked_flags("find"),
    "rg": _rule_blocked_flags("rg"),
    "sort": _rule_blocked_flags("sort"),
    "tree": _rule_blocked_flags("tree"),
    "uniq": _rule_uniq,
    "sed": _rule_sed,
}


# ---------------------------------------------------------------- public ----

def decide(command: str, plugin: bool = False) -> Decision:
    heads: List[str] = []
    try:
        _segments(command.strip(), plugin, heads)
    except Block as b:
        return Decision(False, str(b), heads)
    except RecursionError:
        return Decision(False, "nesting too deep", heads)
    return Decision(True, "", heads)


DENIAL_TEXT = (
    "[bench] Bash is verification-only here: go build/vet/test/list, gofmt -l/-d, read-only "
    "git (status/diff/log/show/grep/ls-files/blame), ls/cat/head/tail/grep/rg/find/wc/diff and "
    "pipes between them; no redirections to files, no $(...) that is not itself allowed, no "
    "background jobs. Change files with the file tools when they are available, or through "
    "agy-delegate when the plugin is loaded."
)
