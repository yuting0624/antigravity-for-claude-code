#!/usr/bin/env python3
"""measure-session.py — token + tool accounting for one Claude Code session.

Usage:
    python3 measure-session.py <session.jsonl> [label] [--join <usage.jsonl>]

Finds the session transcript under ~/.claude/projects/**/<id>.jsonl if you pass a
bare session id instead of a path. Prints the Claude-side token breakdown (exact)
and tool-call counts.

--join reads the delegation usage log the plugin's PostToolUse hook writes
(default ~/.antigravity-usage.jsonl) and prints the executor side of the same
session next to it: calls, tokens, estimated cost, where they went. Both sides on
one screen is the honest number; either alone flatters one of them.
"""
import json, os, sys, glob

def load_prices():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.path.join(here, "..", "prices.json"),
              os.path.join(here, "prices.json"), "prices.json"):
        try:
            with open(p) as f:
                return json.load(f)
        except Exception:
            continue
    return None

def resolve(arg):
    if os.path.isfile(arg):
        return arg
    base = os.path.expanduser("~/.claude/projects")
    exact = glob.glob(f"{base}/**/{arg}.jsonl", recursive=True)
    if exact:
        return exact[0]
    hits = sorted(glob.glob(f"{base}/**/{arg}*.jsonl", recursive=True))
    if len(hits) > 1:
        sys.stderr.write(f"warning: {len(hits)} files match '{arg}'; using {hits[0]}\n")
    return hits[0] if hits else None

def measure(path):
    ti = to = tcc = tcr = turns = 0
    tools = {}
    with open(path) as f:
      for line in f:
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

def session_id_of(path):
    return os.path.splitext(os.path.basename(path))[0] if path else None

def join_usage(log_path, session_id):
    """Sum the delegation-side log for one Claude session (or all, when unknown)."""
    tot = dict(calls=0, errors=0, input=0, output=0, cached=0, cost=0.0, latency=0, by_endpoint={}, by_tool={})
    try:
        f = open(os.path.expanduser(log_path))
    except Exception:
        return None
    with f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if session_id and e.get("claude_session_id") not in (None, session_id):
                continue
            if e.get("error_code") is not None:
                tot["errors"] += 1
                continue
            tot["calls"] += 1
            tot["input"] += e.get("input_tokens", 0) or 0
            tot["output"] += e.get("output_tokens", 0) or 0
            tot["cached"] += e.get("cached_tokens", 0) or 0
            tot["cost"] += e.get("estimated_cost_usd", 0) or 0
            tot["latency"] += e.get("latency_ms", 0) or 0
            ep = f"{e.get('endpoint_class', '?')} ({e.get('endpoint_host', '?')})"
            tot["by_endpoint"][ep] = tot["by_endpoint"].get(ep, 0) + 1
            t = e.get("tool") or "?"
            tot["by_tool"][t] = tot["by_tool"].get(t, 0) + 1
    return tot

if __name__ == "__main__":
    args = [a for a in sys.argv[1:]]
    join = None
    if "--join" in args:
        i = args.index("--join")
        join = args[i + 1] if i + 1 < len(args) else os.path.expanduser("~/.antigravity-usage.jsonl")
        del args[i:i + 2]
    if not args:
        print(__doc__); sys.exit(1)
    path = resolve(args[0])
    label = args[1] if len(args) > 1 else (os.path.basename(path) if path else args[0])
    if not path:
        print(f"session not found: {args[0]}"); sys.exit(1)
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
    print(f"  COST-WEIGHTED  {weighted:,.0f}   <- model-agnostic $-proxy (output 5x, etc.)")
    pr = load_prices()
    if pr and isinstance(pr.get(pr.get("orchestrator", "claude_opus")), dict):
        deck = pr.get("orchestrator", "claude_opus")
        m = pr[deck]; IN, OUT = m.get("in"), m.get("out")
        cw = pr.get("cache_write_mult", 1.25); crd = pr.get("cache_read_mult", 0.10)
        if IN and OUT:
            usd = (r['output']*OUT + r['input']*IN +
                   r['cache_create']*IN*cw + r['cache_read']*IN*crd) / 1e6
            print(f"  est. USD       ${usd:,.4f}   ({deck} deck, prices.json — VERIFY)")
    print(f"  tool calls     {sum(r['tools'].values())}  {r['tools']}")
    print(f"  scope          main session loop only — subagent/workflow transcripts (separate files) NOT counted")
    if join is not None:
        j = join_usage(join, session_id_of(path))
        print(f"=== delegation side ({join}) ===")
        if j is None:
            print("  (no usage log found)")
        else:
            print(f"  calls          {j['calls']}   errors {j['errors']}")
            print(f"  input          {j['input']:,}   cached {j['cached']:,}")
            print(f"  output         {j['output']:,}")
            print(f"  est. USD       ${j['cost']:,.4f}   (server estimate, prices.json on the server side)")
            print(f"  latency        {j['latency']/1000:,.1f}s total")
            print(f"  endpoints      {j['by_endpoint']}")
            print(f"  tools          {j['by_tool']}")
