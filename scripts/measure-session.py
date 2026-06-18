#!/usr/bin/env python3
"""measure-session.py — token + tool accounting for one Claude Code session.

Usage:
    python3 measure-session.py <session.jsonl> [label]

Finds the session transcript under ~/.claude/projects/**/<id>.jsonl if you pass a
bare session id instead of a path. Prints the Claude-side token breakdown (exact)
and tool-call counts. NOTE: this measures the CLAUDE side only — agy/Gemini tokens
are not exposed by `agy --print`, so the cheap-side cost must be priced separately.
"""
import json, os, sys, glob

def resolve(arg):
    if os.path.isfile(arg):
        return arg
    hits = glob.glob(os.path.expanduser(f"~/.claude/projects/**/{arg}*.jsonl"), recursive=True)
    return hits[0] if hits else None

def measure(path):
    ti = to = tcc = tcr = turns = 0
    tools = {}
    for line in open(path):
        try:
            o = json.loads(line)
        except Exception:
            continue
        m = o.get("message")
        if not isinstance(m, dict):
            continue
        c = m.get("content")
        if isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    n = b.get("name", "?")
                    tools[n] = tools.get(n, 0) + 1
        u = m.get("usage")
        if not u:
            continue
        turns += 1
        ti += u.get("input_tokens", 0)
        to += u.get("output_tokens", 0)
        tcc += u.get("cache_creation_input_tokens", 0)
        tcr += u.get("cache_read_input_tokens", 0)
    return dict(turns=turns, input=ti, output=to, cache_create=tcc, cache_read=tcr,
                total=ti + to + tcc + tcr, tools=tools)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    path = resolve(sys.argv[1])
    label = sys.argv[2] if len(sys.argv) > 2 else (os.path.basename(path) if path else sys.argv[1])
    if not path:
        print(f"session not found: {sys.argv[1]}"); sys.exit(1)
    r = measure(path)
    # cost-weighted units, normalized to input=1: output 5x, cache_write 1.25x,
    # cache_read 0.1x (standard Claude multipliers; absolute $ varies by model).
    weighted = (r['output'] * 5 + r['input'] * 1 +
                r['cache_create'] * 1.25 + r['cache_read'] * 0.1)
    print(f"=== {label} ===")
    print(f"  turns          {r['turns']}")
    print(f"  output         {r['output']:,}   <- expensive (frontier)")
    print(f"  input          {r['input']:,}")
    print(f"  cache_create   {r['cache_create']:,}   <- 1.25x input (cache writes)")
    print(f"  cache_read     {r['cache_read']:,}   <- 0.1x input (the cheap re-read)")
    print(f"  TOTAL tokens   {r['total']:,}")
    print(f"  COST-WEIGHTED  {weighted:,.0f}   <- the number that matters ($-proxy)")
    print(f"  tool calls     {sum(r['tools'].values())}  {r['tools']}")
