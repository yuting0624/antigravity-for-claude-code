"""Claude-side accounting: the `claude -p --output-format json` result and the transcript.

Two independent sources are read and reconciled:
  * result.json — `modelUsage` (per-model tokens and Claude Code's own list-price
    costUSD, the primary $ figure), `usage`, `num_turns`, `duration_ms`,
    `permission_denials`, `subtype`, `session_id`;
  * the session transcript JSONL — per-message `usage` sums (must agree with the
    result within a tolerance), the first turn's cache_read (warm-start detector), the
    tool-call histogram, web tool calls, and every Bash call to the wrapper together
    with the conversation ids visible in its tool_result (the join key for AGY_USAGE
    lines that carry no model field).
"""
from __future__ import annotations

import glob
import json
import os
import re
import shlex
from typing import Dict, List, Optional

from common import AGY_HEADS, Prices

CID_RE = re.compile(r'"conversation_id":\s*"([0-9a-fA-F-]{36})"')
WEB_TOOLS = {"WebFetch", "WebSearch"}
WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}


def parse_result(path: str) -> dict:
    """Fields of the final result object; tolerant of a missing or partial file."""
    out = {"present": False, "subtype": None, "is_error": None, "num_turns": 0, "duration_ms": 0,
           "duration_api_ms": 0, "total_cost_usd": None, "usage": {}, "model_usage": {},
           "permission_denials": [], "session_id": None, "result_head": "", "errors": []}
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return out
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
        d = json.loads(raw)
    except Exception as e:  # noqa: BLE001
        # stream-json or a truncated file: take the last parseable object with type=result
        d = None
        for line in raw.splitlines()[::-1]:
            try:
                cand = json.loads(line)
            except Exception:  # noqa: BLE001
                continue
            if isinstance(cand, dict) and cand.get("type") == "result":
                d = cand
                break
        if d is None:
            out["errors"].append("unparseable result: %s" % e)
            return out
    if not isinstance(d, dict):
        out["errors"].append("result is not an object")
        return out
    out["present"] = True
    out["subtype"] = d.get("subtype")
    out["is_error"] = d.get("is_error")
    out["num_turns"] = int(d.get("num_turns") or 0)
    out["duration_ms"] = int(d.get("duration_ms") or 0)
    out["duration_api_ms"] = int(d.get("duration_api_ms") or 0)
    out["total_cost_usd"] = d.get("total_cost_usd")
    out["usage"] = d.get("usage") or {}
    out["model_usage"] = d.get("modelUsage") or {}
    out["permission_denials"] = d.get("permission_denials") or []
    out["session_id"] = d.get("session_id")
    out["result_head"] = str(d.get("result") or "")[:400]
    if d.get("errors"):
        out["errors"] = [str(x) for x in d["errors"]]
    return out


def recompute_list_price(model_usage: Dict[str, dict], prices: Prices) -> (Optional[float], List[str]):
    """Re-derive $ from tokens with the frozen deck; flags name models without a rate."""
    total = 0.0
    flags: List[str] = []
    any_priced = False
    for model, mu in (model_usage or {}).items():
        usd, f = prices.price_claude(model, int(mu.get("inputTokens") or 0), int(mu.get("outputTokens") or 0),
                                     int(mu.get("cacheCreationInputTokens") or 0),
                                     int(mu.get("cacheReadInputTokens") or 0))
        flags.extend(f)
        if usd is not None:
            total += usd
            any_priced = True
    return (total if any_priced else None), flags


def _iter_lines(path: str):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except Exception:  # noqa: BLE001
                continue


def _tier_from_command(cmd: str) -> (str, str, str):
    """(head, tier, model) from a wrapper command; tier defaults to '' (wrapper default)."""
    try:
        toks = shlex.split(cmd, posix=True)
    except ValueError:
        toks = cmd.split()
    head = ""
    for t in toks:
        if "=" in t and not t.startswith("-") and t.split("=", 1)[0].isidentifier():
            continue
        head = os.path.basename(t)
        break
    if head.endswith(".sh"):
        head = head[:-3]
    tier = model = ""
    for i, t in enumerate(toks):
        if t in ("-t", "--tier") and i + 1 < len(toks):
            tier = toks[i + 1]
        elif t.startswith("--tier="):
            tier = t.split("=", 1)[1]
        elif t in ("-m", "--model") and i + 1 < len(toks):
            model = toks[i + 1]
        elif t.startswith("--model="):
            model = t.split("=", 1)[1]
    return head, tier, model


def summarize_transcript(path: str, include_sidechains: bool = True) -> dict:
    """Token sums, first-turn cache read, tool histogram, wrapper calls with their cids."""
    s = {"present": os.path.isfile(path), "turns": 0, "input": 0, "output": 0, "cache_creation": 0,
         "cache_read": 0, "first_turn_cache_read": None, "models": {}, "tool_calls": {},
         "web_tool_calls": 0, "write_tool_calls": 0, "bash_commands": [], "agy_calls": [],
         "sidechain_turns": 0, "wrapper_not_found": 0, "background_delegations": 0, "bash_cap_backgrounds": 0}
    if not s["present"]:
        return s
    pending: Dict[str, dict] = {}  # tool_use_id -> agy call record awaiting its result
    seen_requests = set()  # Claude Code writes one JSONL line per content block, all carrying the same usage
    order = 0
    for rec in _iter_lines(path):
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        sidechain = bool(rec.get("isSidechain"))
        content = msg.get("content")
        if msg.get("role") == "assistant":
            u = msg.get("usage")
            req = rec.get("requestId") or msg.get("id")
            if isinstance(u, dict) and req in seen_requests:
                u = None
            elif isinstance(u, dict) and req:
                seen_requests.add(req)
            if isinstance(u, dict):
                if sidechain:
                    s["sidechain_turns"] += 1
                    if not include_sidechains:
                        continue
                s["turns"] += 1
                inp = int(u.get("input_tokens") or 0)
                out = int(u.get("output_tokens") or 0)
                cc = int(u.get("cache_creation_input_tokens") or 0)
                cr = int(u.get("cache_read_input_tokens") or 0)
                s["input"] += inp; s["output"] += out; s["cache_creation"] += cc; s["cache_read"] += cr
                if s["first_turn_cache_read"] is None and not sidechain:
                    s["first_turn_cache_read"] = cr
                m = msg.get("model") or "?"
                mm = s["models"].setdefault(m, {"turns": 0, "input": 0, "output": 0, "cache_creation": 0, "cache_read": 0})
                mm["turns"] += 1; mm["input"] += inp; mm["output"] += out; mm["cache_creation"] += cc; mm["cache_read"] += cr
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    name = str(block.get("name") or "?")
                    s["tool_calls"][name] = s["tool_calls"].get(name, 0) + 1
                    if name in WEB_TOOLS:
                        s["web_tool_calls"] += 1
                    if name in WRITE_TOOLS:
                        s["write_tool_calls"] += 1
                    if name == "Bash":
                        cmd = str((block.get("input") or {}).get("command") or "")
                        s["bash_commands"].append(cmd[:500])
                        head, tier, model = _tier_from_command(cmd)
                        if head in AGY_HEADS:
                            if (block.get("input") or {}).get("run_in_background"):
                                s["background_delegations"] += 1  # Claude Code's background Bash: the wrapper keeps writing after the call returns
                            order += 1
                            call = {"order": order, "tool_use_id": block.get("id"), "head": head,
                                    "tier": tier, "model": model, "conversation_ids": [], "command": cmd[:300]}
                            s["agy_calls"].append(call)
                            if block.get("id"):
                                pending[block["id"]] = call
        elif msg.get("role") == "user" and isinstance(content, list):
            texts: List[str] = []
            tur = rec.get("toolUseResult")
            if isinstance(tur, dict):
                for k in ("stdout", "stderr"):
                    if isinstance(tur.get(k), str):
                        texts.append(tur[k])
                        low = tur[k].lower()
                        if "agy-delegate" in low and ("command not found" in low or "not found" in low.split("agy-delegate", 1)[1][:80]):
                            s["wrapper_not_found"] += 1
                if "moved to the background (id" in ((tur.get("stdout") or "") + (tur.get("stderr") or "")).lower():
                    s["bash_cap_backgrounds"] += 1  # Claude Code pushed a command past the Bash timeout into the background
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                c0 = block.get("content")
                t0 = c0 if isinstance(c0, str) else " ".join(x.get("text", "") for x in c0 if isinstance(x, dict)) if isinstance(c0, list) else ""
                tur0 = rec.get("toolUseResult")
                if "moved to the background (id" in t0.lower() or (isinstance(tur0, dict) and tur0.get("backgroundTaskId")):
                    s["bash_cap_backgrounds"] += 1  # Claude Code: "Command did not complete within its N s timeout and was moved to the background"
                tid = block.get("tool_use_id")
                if tid not in pending:
                    continue
                c = block.get("content")
                if isinstance(c, str):
                    texts.append(c)
                elif isinstance(c, list):
                    for part in c:
                        if isinstance(part, dict) and isinstance(part.get("text"), str):
                            texts.append(part["text"])
                cids = []
                for t in texts:
                    cids.extend(CID_RE.findall(t))
                seen = []
                for cid in cids:
                    if cid not in seen:
                        seen.append(cid)
                pending[tid]["conversation_ids"] = seen
                del pending[tid]
    return s


def find_transcripts(config_dir: str, session_id: str) -> List[str]:
    """The main transcript plus any subagent transcripts for a session under CLAUDE_CONFIG_DIR."""
    main = glob.glob(os.path.join(config_dir, "projects", "*", session_id + ".jsonl"))
    subs = glob.glob(os.path.join(config_dir, "projects", "*", session_id, "**", "*.jsonl"), recursive=True)
    return sorted(main) + sorted(subs)


def reconcile(result: dict, transcript: dict, tolerance: float = 0.02) -> dict:
    """Result `usage` vs transcript sums; a mismatch is reported, never repaired."""
    ru = result.get("usage") or {}
    pairs = {"input": int(ru.get("input_tokens") or 0), "output": int(ru.get("output_tokens") or 0),
             "cache_creation": int(ru.get("cache_creation_input_tokens") or 0),
             "cache_read": int(ru.get("cache_read_input_tokens") or 0)}
    diffs = {}
    ok = True
    for k, rv in pairs.items():
        tv = int(transcript.get(k) or 0)
        base = max(rv, tv, 1)
        rel = abs(rv - tv) / base
        diffs[k] = {"result": rv, "transcript": tv, "rel": round(rel, 4)}
        if rel > tolerance and max(rv, tv) > 1000:
            ok = False
    return {"ok": ok, "fields": diffs}


LONG_CONTEXT_THRESHOLD = 200_000
LONG_CONTEXT_MULT_IN = 2.0    # published 1M-context pricing: input (incl. cache) x2 above 200k
LONG_CONTEXT_MULT_OUT = 1.5   # output x1.5 above 200k


def long_context_estimate(path: str, prices: Prices) -> dict:
    """List price recomputed per request with the long-context multipliers applied to every
    request whose context (input + cache write + cache read) exceeds 200k tokens. Claude
    Code's own total_cost_usd may or may not apply them; the billing export is the arbiter,
    this is the upper-bound estimate reported beside it."""
    out = {"usd_long_context_est": 0.0, "requests": 0, "requests_over_200k": 0, "ctx_tokens_over_200k_share": None}
    if not os.path.isfile(path):
        return out
    seen = set(); tot_ctx = 0; big_ctx = 0; usd = 0.0
    for rec in _iter_lines(path):
        msg = rec.get("message")
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        u = msg.get("usage")
        req = rec.get("requestId") or msg.get("id")
        if not isinstance(u, dict) or req in seen:
            continue
        seen.add(req)
        inp = int(u.get("input_tokens") or 0); outp = int(u.get("output_tokens") or 0)
        cc = int(u.get("cache_creation_input_tokens") or 0); cr = int(u.get("cache_read_input_tokens") or 0)
        ctx = inp + cc + cr
        base, _ = prices.price_claude(msg.get("model") or "", inp, outp, cc, cr)
        if base is None:
            continue
        out["requests"] += 1; tot_ctx += ctx
        if ctx > LONG_CONTEXT_THRESHOLD:
            out["requests_over_200k"] += 1; big_ctx += ctx
            key = prices.claude_key(msg.get("model") or "")
            d = prices.data[key]; pin, pout = float(d["in"]), float(d["out"])
            usd += (inp * pin * LONG_CONTEXT_MULT_IN + cc * pin * prices.cache_write_mult * LONG_CONTEXT_MULT_IN
                    + cr * pin * prices.cache_read_mult * LONG_CONTEXT_MULT_IN + outp * pout * LONG_CONTEXT_MULT_OUT) / 1e6
        else:
            usd += base
    out["usd_long_context_est"] = round(usd, 6)
    out["ctx_tokens_over_200k_share"] = round(big_ctx / tot_ctx, 4) if tot_ctx else None
    return out
