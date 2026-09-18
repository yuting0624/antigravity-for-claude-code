"""Gemini-side accounting from the wrapper's AGY_USAGE_LOG.

Each `AGY_USAGE {json}` line is one delegation's envelope summary; `AGY_SIGNAL {json}`
lines mark failures. Pricing follows docs/POC-PLAYBOOK.md §5 exactly:
    input×in + output×out + cache_read×cached_in   (three terms, no subtraction)
and the invariant input + output == total is asserted per line — a violation stops the
scorer with InvariantError instead of reinterpreting the counters.

Tier resolution per line, in this order, each counted in `join`:
  1. `tier`/`model` fields on the line (plugin ≥ 0.28.0)            -> by_model_field
  2. the wrapper call in the transcript whose tool_result shows the
     line's conversation_id                                          -> by_conversation_id
  3. in-order pairing, only when unmatched lines and unmatched calls
     are equal in number                                              -> by_order
  4. unknown: priced at the pro rate (conservative against the hybrid) -> unresolved
"""
from __future__ import annotations

import json
from typing import Dict, List, Optional

from common import Prices


class InvariantError(Exception):
    """input + output != total on an AGY_USAGE line."""


def parse_log(path: Optional[str]) -> List[dict]:
    recs: List[dict] = []
    if not path:
        return recs
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return recs
    for i, line in enumerate(lines, 1):
        line = line.strip()
        for kind, prefix in (("usage", "AGY_USAGE "), ("signal", "AGY_SIGNAL ")):
            if line.startswith(prefix):
                try:
                    obj = json.loads(line[len(prefix):])
                except Exception:  # noqa: BLE001
                    recs.append({"kind": "bad", "line_no": i, "raw": line[:300]})
                    break
                recs.append({"kind": kind, "line_no": i, "raw": obj})
                break
    return recs


def check_invariant(usage: dict) -> None:
    inp = int(usage.get("input") or 0)
    out = int(usage.get("output") or 0)
    tot = int(usage.get("total") or 0)
    if inp + out != tot:
        raise InvariantError("input %d + output %d != total %d" % (inp, out, tot))


def summarize(records: List[dict], prices: Prices, agy_calls: Optional[List[dict]] = None) -> dict:
    """Price every usage line; join tiers; aggregate. `agy_calls` comes from claude_usage."""
    agy_calls = list(agy_calls or [])
    usage_lines = [r for r in records if r["kind"] == "usage"]
    signals = [r for r in records if r["kind"] == "signal"]
    bad = [r for r in records if r["kind"] == "bad"]

    for r in usage_lines:
        check_invariant(r["raw"].get("usage") or {})

    cid_to_call: Dict[str, dict] = {}
    for c in agy_calls:
        for cid in c.get("conversation_ids") or []:
            cid_to_call.setdefault(cid, c)

    join = {"by_model_field": 0, "by_conversation_id": 0, "by_order": 0, "unresolved": 0}
    resolved: List[dict] = []
    unmatched_lines: List[dict] = []
    used_calls = set()
    for r in usage_lines:
        raw = r["raw"]
        tier = str(raw.get("tier") or "")
        model = str(raw.get("model") or "")
        cid = str(raw.get("conversation_id") or "")
        if tier or model:
            join["by_model_field"] += 1
            resolved.append({"rec": r, "tier": tier, "model": model, "how": "field"})
            continue
        call = cid_to_call.get(cid) if cid else None
        if call is not None:
            join["by_conversation_id"] += 1
            used_calls.add(id(call))
            resolved.append({"rec": r, "tier": call.get("tier") or "flash", "model": call.get("model") or "", "how": "cid"})
            continue
        unmatched_lines.append(r)
    unmatched_calls = [c for c in agy_calls if id(c) not in used_calls and c.get("head") in ("agy-delegate", "agy-job")]
    if unmatched_lines and len(unmatched_lines) == len(unmatched_calls):
        for r, c in zip(unmatched_lines, unmatched_calls):
            join["by_order"] += 1
            resolved.append({"rec": r, "tier": c.get("tier") or "flash", "model": c.get("model") or "", "how": "order"})
    else:
        for r in unmatched_lines:
            join["unresolved"] += 1
            resolved.append({"rec": r, "tier": "", "model": "", "how": "unresolved"})

    by_tier: Dict[str, dict] = {}
    totals = {"input": 0, "output": 0, "thinking": 0, "cache_read": 0, "total": 0}
    shadow = 0.0
    flags: List[str] = []
    conversation_ids: List[str] = []
    durations: List[float] = []
    succeeded = 0
    for item in resolved:
        raw = item["rec"]["raw"]
        u = raw.get("usage") or {}
        if item["how"] == "unresolved":
            key, kflags = None, []
            label = "unknown"
        else:
            key, kflags = prices.gemini_key(item["model"], item["tier"])
            label = item["tier"] or (key or "unknown")
        usd, pflags = prices.price_gemini(u, key)
        for f in kflags + pflags:
            if f not in flags:
                flags.append(f)
        bt = by_tier.setdefault(label, {"calls": 0, "input": 0, "output": 0, "thinking": 0, "cache_read": 0, "usd": 0.0})
        bt["calls"] += 1
        for k in ("input", "output", "thinking", "cache_read"):
            bt[k] += int(u.get(k) or 0)
            totals[k] += int(u.get(k) or 0)
        totals["total"] += int(u.get("total") or 0)
        bt["usd"] += usd
        shadow += usd
        if str(raw.get("status") or "") == "SUCCESS":
            succeeded += 1
        cid = str(raw.get("conversation_id") or "")
        if cid and cid not in conversation_ids:
            conversation_ids.append(cid)
        ds = raw.get("duration_seconds")
        if isinstance(ds, (int, float)) and ds > 0:
            durations.append(float(ds))
    for bt in by_tier.values():
        bt["usd"] = round(bt["usd"], 6)

    sig_counts: Dict[str, int] = {}
    for r in signals:
        st = str(r["raw"].get("status") or "?")
        sig_counts[st] = sig_counts.get(st, 0) + 1
    # A signal that names a pre-envelope failure is a delegation that never produced a
    # usage line; TIMEOUT/PERMISSION signals accompany a usage line and are not extra.
    pre = {"AGY_MISSING", "QUOTA_EXHAUSTED", "AUTH_REQUIRED", "MODEL_UNAVAILABLE", "AGY_FAILED"}
    signal_only = sum(1 for r in signals if str(r["raw"].get("status")) in pre)
    delegations = len(usage_lines) + signal_only
    zero_usage = sum(1 for r in usage_lines if int((r["raw"].get("usage") or {}).get("total") or 0) == 0)

    return {
        "delegations": delegations,
        "usage_lines": len(usage_lines),
        "signal_only": signal_only,
        "succeeded": succeeded,
        "zero_usage_lines": zero_usage,
        "signals": sig_counts,
        "bad_lines": len(bad),
        "join": join,
        "by_tier": by_tier,
        "totals": totals,
        "invariant_ok": True,
        "shadow_usd": round(shadow, 6),
        "shadow_usd_is_lower_bound": True,
        "flags": flags,
        "conversation_ids": conversation_ids,
        "agy_duration_s_sum": round(sum(durations), 3),
        "wrapper_calls_in_transcript": len(agy_calls),
    }
