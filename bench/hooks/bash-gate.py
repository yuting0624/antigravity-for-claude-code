#!/usr/bin/env python3
"""PreToolUse(Bash) hook: verification-only shell policy for every benchmark arm.

Reads the hook JSON on stdin, decides with bench/harness/gates.py, appends one JSON line
per decision to $BENCH_TRACE_LOG (if set) and exits 2 with the reason on stderr to block.
Fails closed: unparseable input or an internal error blocks. $BENCH_PLUGIN=1 enables the
wrapper heads (hybrid arms).
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "harness"))


def log(rec):
    path = os.environ.get("BENCH_TRACE_LOG")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main():
    try:
        import gates  # noqa: E402
        data = json.load(sys.stdin)
        cmd = str((data.get("tool_input") or {}).get("command", ""))
        plugin = os.environ.get("BENCH_PLUGIN", "0") == "1"
        d = gates.decide(cmd, plugin=plugin)
        log({"ts": time.time(), "event": "gate", "decision": "allow" if d.allow else "block",
             "reason": d.reason, "heads": d.heads, "tool_use_id": data.get("tool_use_id"),
             "command": cmd[:2000]})
        if d.allow:
            return 0
        sys.stderr.write("[bench] blocked: %s\n%s\n" % (d.reason, gates.DENIAL_TEXT))
        return 2
    except Exception as e:  # fail closed
        log({"ts": time.time(), "event": "gate", "decision": "block", "reason": "hook error: %s" % e})
        sys.stderr.write("[bench] blocked: gate error (%s)\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
