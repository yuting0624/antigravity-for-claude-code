"""Aggregate run.json + judge records into aggregate.json and tables.md.

Metric definitions (docs/POC-PLAYBOOK.md §5): cost-of-pass = total spend ÷ passes; per
arm and per size class; paired per-task ratios against the reference arm with a seeded
task-level bootstrap. Every number here is derivable from the committed records.
"""
from __future__ import annotations

import glob
import json
import math
import os
import random
import statistics
from typing import Dict, List, Optional

from common import RESULTS_DIR, read_json, write_json, write_text

AXES = ("consistency", "edge_cases", "scope", "readability", "robustness", "maintainability")
SIZES = ("small", "medium", "large")


def load_runs(run_id: str) -> List[dict]:
    """Every run.json whose queue item finished (`done`). A record left behind by an
    attempt that was later rerun or whose item was skipped (measured: one suspended
    k6 attempt) is not a result and is not loaded."""
    qpath = os.path.join(RESULTS_DIR, run_id, "queue.json")
    done = None
    if os.path.isfile(qpath):
        q = read_json(qpath)
        done = {"%s__%s__r%d" % (i["task_id"], i["arm"], i["rep"]) for i in q["items"] if i["status"] == "done"}
    recs = []
    for p in sorted(glob.glob(os.path.join(RESULTS_DIR, run_id, "runs", "*", "run.json"))):
        key = os.path.basename(os.path.dirname(p))
        if done is not None and key not in done:
            continue
        r = read_json(p)
        r["_path"] = p
        recs.append(r)
    return recs


def _median(xs: List[float]) -> Optional[float]:
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 4) if xs else None


def _cost(r: dict) -> Optional[float]:
    return r.get("cost", {}).get("total_usd")


_BILLED = None


def billed_gemini_usd(r: dict) -> float:
    """Gemini side at the unit prices the billing export showed for this project (see
    prices.lock.json `_observed_billing`); pro-tier tokens keep the deck rate (no Pro SKU
    rows were observed in the run window)."""
    global _BILLED
    if _BILLED is None:
        from common import PRICES_LOCK
        _BILLED = (read_json(PRICES_LOCK).get("_observed_billing") or {}).get("gemini_flash_38") or {"in": 0.75, "out": 3.75, "cached_in": 0.075}
    usd = 0.0
    for tier, bt in (r.get("agy", {}).get("by_tier") or {}).items():
        if tier in ("flash", "flash-lo") or tier.startswith("gemini_flash"):
            usd += (bt.get("input", 0) * _BILLED["in"] + bt.get("output", 0) * _BILLED["out"] + bt.get("cache_read", 0) * _BILLED["cached_in"]) / 1e6
        else:
            usd += bt.get("usd", 0.0)
    return usd


def _cost_billed(r: dict) -> Optional[float]:
    c = r.get("cost", {}).get("claude_usd")
    return None if c is None else c + billed_gemini_usd(r)


def arm_summary(runs: List[dict]) -> dict:
    ok = [r for r in runs if r.get("status") == "ok" and not r.get("violations")]
    excluded = [r for r in runs if r.get("violations")]
    passes = [r for r in ok if r.get("outcome", {}).get("pass")]
    costs = [_cost(r) for r in ok if _cost(r) is not None]
    pass_costs = [_cost(r) for r in passes if _cost(r) is not None]
    total = round(sum(costs), 4) if costs else 0.0
    return {
        "n": len(runs), "runs_ok": len(ok), "excluded": len(excluded),
        "pass": len(passes), "pass_rate": round(len(passes) / len(ok), 4) if ok else None,
        "hidden_pass": sum(1 for r in ok if r.get("outcome", {}).get("hidden_pass")),
        "cost_total_usd": total,
        "cost_of_pass_usd": round(total / len(passes), 4) if passes else None,
        "cost_of_pass_billed_usd": (round(sum(_cost_billed(r) or 0 for r in ok) / len(passes), 4) if passes else None),
        "cost_of_pass_claude_only_usd": (round(sum(r["cost"].get("claude_usd") or 0 for r in ok) / len(passes), 4) if passes else None),
        "gemini_billed_usd": round(sum(billed_gemini_usd(r) for r in ok), 4),
        "cost_pass_median": _median(pass_costs), "cost_pass_min": round(min(pass_costs), 4) if pass_costs else None,
        "cost_pass_max": round(max(pass_costs), 4) if pass_costs else None,
        "cost_all_median": _median(costs),
        "claude_usd": round(sum(r["cost"].get("claude_usd") or 0 for r in ok), 4),
        "gemini_usd": round(sum(r["cost"].get("gemini_usd") or 0 for r in ok), 4),
        "wall_median_s": _median([r.get("agent_wall_s") for r in ok]),
        "turns_median": _median([r.get("claude", {}).get("num_turns") for r in ok]),
        "delegations_median": _median([r.get("agy", {}).get("delegations") for r in ok]),
        "delegations_zero_runs": sum(1 for r in ok if (r.get("agy", {}).get("delegations") or 0) == 0),
        "agy_writes_runs": sum(1 for r in ok if (r.get("writes", {}).get("agy") or 0) > 0),
        "claude_bash_writes": sum(r.get("writes", {}).get("claude_bash") or 0 for r in ok),
        "denials_median": _median([r.get("claude", {}).get("permission_denials") for r in ok]),
        "warm_starts": sum(1 for r in ok if r.get("claude", {}).get("warm_start")),
        "caps_hit": sum(1 for r in ok if str(r.get("claude", {}).get("subtype", "")).startswith("error_") or r.get("claude", {}).get("subtype") == "killed_wall"),
        "tampered": sum(1 for r in ok if r.get("outcome", {}).get("hidden_test_tampered")),
        "usage_reconciles": sum(1 for r in ok if r.get("claude", {}).get("usage_reconciles")),
        "slept_runs": sum(1 for r in ok if (r.get("suspended_s") or 0) > 30),
        "claude_usd_long_context_est": round(sum((r.get("claude", {}).get("long_context") or {}).get("usd_long_context_est") or (r["cost"].get("claude_usd") or 0) for r in ok), 4),
        "runs_with_200k_requests": sum(1 for r in ok if ((r.get("claude", {}).get("long_context") or {}).get("requests_over_200k") or 0) > 0),
        "tree_pass": sum(1 for r in ok if r.get("outcome", {}).get("tree_pass")),
        "flaky_retry_passes": sum(1 for r in ok if ((r.get("outcome", {}).get("full_suite") or {}).get("flaky_retry") or {}).get("all_passed_on_retry")),
        "violations": {v: sum(1 for r in excluded if v in r.get("violations", [])) for v in sorted({x for r in excluded for x in r.get("violations", [])})},
    }


def per_task_cost_of_pass(runs: List[dict], costf=None) -> Dict[str, Dict[str, dict]]:
    """task -> arm -> {cost, passes, n}."""
    costf = costf or _cost
    out: Dict[str, Dict[str, dict]] = {}
    for r in runs:
        if r.get("status") != "ok" or r.get("violations"):
            continue
        t = out.setdefault(r["task_id"], {})
        a = t.setdefault(r["arm"], {"cost": 0.0, "passes": 0, "n": 0, "size_class": r.get("size_class")})
        a["cost"] += costf(r) or 0.0
        a["passes"] += 1 if r.get("outcome", {}).get("pass") else 0
        a["n"] += 1
    return out


def bootstrap_ratio(per_task: Dict[str, Dict[str, dict]], arm: str, ref: str, tasks: List[str],
                    boots: int, seed: int) -> dict:
    """Ratio of Σcost/Σpasses (arm) to the same for ref, resampling tasks with replacement."""
    tasks = [t for t in tasks if arm in per_task.get(t, {}) and ref in per_task.get(t, {})]
    rng = random.Random(seed)

    def cop(sample: List[str], a: str) -> Optional[float]:
        c = sum(per_task[t][a]["cost"] for t in sample)
        p = sum(per_task[t][a]["passes"] for t in sample)
        return (c / p) if p else None

    def ratio(sample: List[str]) -> Optional[float]:
        a, b = cop(sample, arm), cop(sample, ref)
        return (a / b) if (a is not None and b) else None

    point = ratio(tasks) if tasks else None
    draws: List[float] = []
    undefined = 0
    for _ in range(boots if tasks else 0):
        s = [rng.choice(tasks) for _ in tasks]
        v = ratio(s)
        if v is None:
            undefined += 1
        else:
            draws.append(v)
    draws.sort()
    ci = None
    if draws:
        lo = draws[int(0.025 * (len(draws) - 1))]
        hi = draws[int(0.975 * (len(draws) - 1))]
        ci = [round(lo, 4), round(hi, 4)]
    pass_diff = None
    if tasks:
        na = sum(per_task[t][arm]["n"] for t in tasks)
        nb = sum(per_task[t][ref]["n"] for t in tasks)
        pa = sum(per_task[t][arm]["passes"] for t in tasks)
        pb = sum(per_task[t][ref]["passes"] for t in tasks)
        pass_diff = round((pa / na if na else 0) - (pb / nb if nb else 0), 4)
    return {"arm": arm, "ref": ref, "n_tasks": len(tasks), "point": round(point, 4) if point is not None else None,
            "ci95": ci, "boot": boots, "undefined_draws": undefined, "seed": seed, "pass_rate_diff": pass_diff,
            "per_task": [{"task_id": t, "arm_cop": (per_task[t][arm]["cost"] / per_task[t][arm]["passes"]) if per_task[t][arm]["passes"] else None,
                          "ref_cop": (per_task[t][ref]["cost"] / per_task[t][ref]["passes"]) if per_task[t][ref]["passes"] else None,
                          "size_class": per_task[t][arm]["size_class"]} for t in tasks]}


# ---------------------------------------------------------------- judges ----

def _rank_avg(values: List[float]) -> List[float]:
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        r = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = r
        i = j + 1
    return ranks


def spearman(xs: List[float], ys: List[float]) -> Optional[float]:
    if len(xs) < 3 or len(xs) != len(ys):
        return None
    rx, ry = _rank_avg(xs), _rank_avg(ys)
    return pearson(rx, ry)


def pearson(xs: List[float], ys: List[float]) -> Optional[float]:
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx == 0 or syy == 0:
        return None
    return round(sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / math.sqrt(sxx * syy), 4)


def judge_summary(run_id: str, runs: List[dict], include_runs: Optional[List[str]] = None) -> dict:
    jdir = os.path.join(RESULTS_DIR, run_id, "judge")
    bm_path = os.path.join(jdir, "blind-map.json")
    if not os.path.isfile(bm_path):
        return {"present": False}
    blind = dict(read_json(bm_path)["candidates"])
    run_by_key = {r["run_key"]: r for r in runs}
    recs = [read_json(p) for p in glob.glob(os.path.join(jdir, "*", "*__*.json"))]
    for include_run in (include_runs or []):
        # judge records of the reference arms live with their own run; bring in only the
        # run-sourced candidates (anchors come from this run's own judging)
        ib = os.path.join(RESULTS_DIR, include_run, "judge", "blind-map.json")
        if os.path.isfile(ib):
            iblind = read_json(ib)["candidates"]
            keep = {cid for cid, v in iblind.items() if str(v.get("source", "")).startswith("run:") and v["source"][4:] in run_by_key}
            blind.update({cid: iblind[cid] for cid in keep})
            recs += [r for r in (read_json(p) for p in glob.glob(os.path.join(RESULTS_DIR, include_run, "judge", "*", "*__*.json"))) if r.get("candidate_id") in keep]
    recs = [r for r in recs if r.get("status") == "ok"]
    by_arm: Dict[str, Dict[str, dict]] = {}
    per_cand: Dict[str, Dict[str, float]] = {}  # cid -> judge -> mean
    task_acc: Dict[str, Dict[str, Dict[str, List[float]]]] = {}  # task -> arm -> judge -> candidate means
    author_ranks: Dict[str, Dict[str, int]] = {}
    null_means: Dict[str, List[float]] = {}
    fails = sum(1 for p in glob.glob(os.path.join(jdir, "*", "*__*.json")) if read_json(p).get("status") != "ok")
    recs = [r for r in recs if not str(blind.get(r["candidate_id"], {}).get("source", "")).startswith("run:")
            or blind[r["candidate_id"]]["source"][4:] in run_by_key]  # candidates from attempts that are not results are dropped
    for r in recs:
        src = blind.get(r["candidate_id"], {}).get("source", "?")
        arm = "author" if src == "author" else ("null" if src == "null" else run_by_key.get(src[4:], {}).get("arm", "?"))
        d = by_arm.setdefault(arm, {}).setdefault(r["judge"], {"n": 0, "mean": 0.0, **{a: 0.0 for a in AXES}})
        d["n"] += 1
        d["mean"] += r["mean"]
        for a in AXES:
            d[a] += r["scores"][a]
        per_cand.setdefault(r["candidate_id"], {})[r["judge"]] = r["mean"]
        task_acc.setdefault(r["task_id"], {}).setdefault(arm, {}).setdefault(r["judge"], []).append(r["mean"])
        if src == "null":
            null_means.setdefault(r["judge"], []).append(r["mean"])
    for arm, js in by_arm.items():
        for j, d in js.items():
            n = d["n"]
            d["mean"] = round(d["mean"] / n, 3)
            for a in AXES:
                d[a] = round(d[a] / n, 3)
    # author rank per task per judge
    by_task_judge: Dict[str, Dict[str, List[tuple]]] = {}
    for r in recs:
        by_task_judge.setdefault(r["task_id"], {}).setdefault(r["judge"], []).append((r["candidate_id"], r["mean"]))
    for t, js in by_task_judge.items():
        for j, items in js.items():
            items.sort(key=lambda x: -x[1])
            for rank, (cid, _) in enumerate(items, 1):
                if blind.get(cid, {}).get("source") == "author":
                    author_ranks.setdefault(j, {})[t] = "%d/%d" % (rank, len(items))
    # agreement
    both = [c for c, js in per_cand.items() if "claude" in js and "gemini" in js]
    xs = [per_cand[c]["claude"] for c in both]
    ys = [per_cand[c]["gemini"] for c in both]
    within1 = round(sum(1 for x, y in zip(xs, ys) if abs(x - y) <= 1) / len(both), 3) if both else None
    # point-biserial: judge mean vs pass, run candidates only
    pb: Dict[str, Optional[float]] = {}
    for j in ("claude", "gemini"):
        pairs = []
        for cid, js in per_cand.items():
            src = blind.get(cid, {}).get("source", "")
            if src.startswith("run:") and j in js and src[4:] in run_by_key:
                pairs.append((js[j], 1.0 if run_by_key[src[4:]].get("outcome", {}).get("pass") else 0.0))
        pb[j] = pearson([p[0] for p in pairs], [p[1] for p in pairs]) if len(pairs) >= 3 else None
    return {"present": True, "records_ok": len(recs), "records_failed": fails, "task_means": {t: {a: {j: round(sum(v) / len(v), 4) for j, v in js.items()} for a, js in arms_.items()} for t, arms_ in task_acc.items()}, "by_arm": by_arm,
            "anchors": {"null_mean_by_judge": {j: round(statistics.mean(v), 3) for j, v in null_means.items()},
                        "null_max_by_judge": {j: max(v) for j, v in null_means.items()},
                        "author_rank_by_task": author_ranks},
            "agreement": {"n_candidates_both": len(both), "spearman_mean": spearman(xs, ys), "within1_pct": within1},
            "judge_vs_pass_pointbiserial": pb}


def judge_paired_diff(task_means: Dict[str, Dict[str, Dict[str, float]]], arm: str, ref: str, tasks: List[str],
                      boots: int, seed: int) -> Dict[str, dict]:
    """Per judge: mean over tasks of (arm's task mean − ref's task mean), tasks resampled with replacement."""
    out: Dict[str, dict] = {}
    for j in ("claude", "gemini"):
        ts = [t for t in tasks if j in task_means.get(t, {}).get(arm, {}) and j in task_means.get(t, {}).get(ref, {})]
        if not ts:
            continue
        diffs = {t: task_means[t][arm][j] - task_means[t][ref][j] for t in ts}
        rng = random.Random(seed)
        bs = []
        for _ in range(boots):
            sample = [rng.choice(ts) for _ in ts]
            bs.append(sum(diffs[t] for t in sample) / len(sample))
        bs.sort()
        out[j] = {"point": round(sum(diffs.values()) / len(ts), 3),
                  "ci95": [round(bs[int(0.025 * boots)], 3), round(bs[min(boots - 1, int(0.975 * boots))], 3)], "n_tasks": len(ts)}
    return out


def _parse_include(include: Optional[str]) -> List[tuple]:
    """"run:arm1,arm2;run2:arm3" -> [("run", {"arm1", "arm2"}), ("run2", {"arm3"})]."""
    specs = []
    for part in (include or "").split(";"):
        part = part.strip()
        if not part:
            continue
        other, arms_s = part.split(":", 1)
        specs.append((other, {a for a in arms_s.split(",") if a}))
    return specs


# ------------------------------------------------------------------ main ----

def analyze(run_id: str, ref_arm: str = "solo-opus", boots: int = 10000, seed: int = 20260914,
            include: Optional[str] = None, also_ref: Optional[str] = None) -> dict:
    """`include` = "other-run-id:arm1,arm2[;another-run:arm3]" merges those arms' finished
    runs from other run ids (a follow-up study reuses earlier reference arms; recorded in the
    aggregate). `also_ref` = "arm[,arm]" adds paired comparisons of this run's own arms
    against those arms besides `ref_arm`."""
    runs = load_runs(run_id)
    native_arms = sorted({r["arm"] for r in runs})
    specs = _parse_include(include)
    for other, wanted in specs:
        extra = [r for r in load_runs(other) if r["arm"] in wanted]
        for r in extra:
            r["_from_run"] = other
        runs += extra
    arms = sorted({r["arm"] for r in runs})
    refs = [ref_arm] + [a for a in (also_ref or "").split(",") if a and a != ref_arm]
    per_task = per_task_cost_of_pass(runs)
    per_task_billed = per_task_cost_of_pass(runs, _cost_billed)
    per_task_claude = per_task_cost_of_pass(runs, lambda r: r["cost"].get("claude_usd"))
    tasks = sorted(per_task)
    agg = {"schema": "bench.aggregate/1", "run_id": run_id, "generated_at": __import__("common").now_iso(),
           "n_runs": len(runs), "included_from": include, "tasks": tasks, "arms": {}, "paired": {}, "by_size": {},
           "judge": judge_summary(run_id, runs, [o for o, _ in specs]),
           "versions": (runs[0].get("versions") if runs else {}), "prices_lock_sha256": (runs[0].get("prices_lock_sha256") if runs else None),
           "exclusions": [{"run_key": r["run_key"], "violations": r["violations"]} for r in runs if r.get("violations")]}
    agg["sensitivity_no_sleep"] = {}
    for arm in arms:
        agg["arms"][arm] = arm_summary([r for r in runs if r["arm"] == arm])
        agg["sensitivity_no_sleep"][arm] = arm_summary([r for r in runs if r["arm"] == arm and (r.get("suspended_s") or 0) <= 30])
        agg["arms"][arm]["by_size"] = {s: arm_summary([r for r in runs if r["arm"] == arm and r.get("size_class") == s])
                                       for s in SIZES if any(r.get("size_class") == s for r in runs if r["arm"] == arm)}
        for ref in refs:
            if arm == ref or ref not in arms or (ref != ref_arm and arm not in native_arms):
                continue
            agg["paired"]["%s_vs_%s" % (arm, ref)] = bootstrap_ratio(per_task, arm, ref, tasks, boots, seed)
            agg.setdefault("paired_billed", {})["%s_vs_%s" % (arm, ref)] = bootstrap_ratio(per_task_billed, arm, ref, tasks, boots, seed)
            agg.setdefault("paired_claude_only", {})["%s_vs_%s" % (arm, ref)] = bootstrap_ratio(per_task_claude, arm, ref, tasks, boots, seed)
            for s in SIZES:
                st = [t for t in tasks if any(a.get("size_class") == s for a in per_task[t].values())]
                if st:
                    agg["paired"]["%s_vs_%s@%s" % (arm, ref, s)] = bootstrap_ratio(per_task, arm, ref, st, boots, seed)
                    agg["paired_billed"]["%s_vs_%s@%s" % (arm, ref, s)] = bootstrap_ratio(per_task_billed, arm, ref, st, boots, seed)
                    agg["paired_claude_only"]["%s_vs_%s@%s" % (arm, ref, s)] = bootstrap_ratio(per_task_claude, arm, ref, st, boots, seed)
    tm = agg["judge"].get("task_means") if agg["judge"].get("present") else None
    if tm:
        pd: Dict[str, dict] = {}
        for ref in refs:
            for arm in arms:
                if arm == ref or ref not in arms or (ref != ref_arm and arm not in native_arms):
                    continue
                d = judge_paired_diff(tm, arm, ref, tasks, boots, seed)
                if d:
                    pd["%s_vs_%s" % (arm, ref)] = d
        agg["judge"]["paired_diff"] = pd
    out_dir = os.path.join(RESULTS_DIR, run_id)
    write_json(os.path.join(out_dir, "aggregate.json"), agg)
    write_text(os.path.join(out_dir, "tables.md"), render_tables(agg))
    return agg


def render_block(agg: dict, kind: str) -> str:
    """One markdown table per kind; the doc guard regenerates quoted blocks with this."""
    L: List[str] = []
    if kind == "arms":
        L.append("| arm | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes (min–max) | Claude $ | Gemini $ deck / billed | wall med s | turns med | delegations med (0-runs) | denials med | warm starts | caps hit |")
        L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for arm, a in agg["arms"].items():
            L.append("| %s | %d | %d/%d | %s | %s | %s (%s–%s) | %.2f | %.2f / %.2f | %s | %s | %s (%d) | %s | %d | %d |" % (
                arm, a["runs_ok"], a["pass"], a["runs_ok"], _f(a["cost_of_pass_usd"]), _f(a.get("cost_of_pass_billed_usd")), _f(a["cost_pass_median"]), _f(a["cost_pass_min"]),
                _f(a["cost_pass_max"]), a["claude_usd"], a["gemini_usd"], a.get("gemini_billed_usd") or 0.0, _f(a["wall_median_s"]), _f(a["turns_median"]),
                _f(a["delegations_median"]), a["delegations_zero_runs"], _f(a["denials_median"]), a["warm_starts"], a["caps_hit"]))
    elif kind == "size":
        L.append("| arm | size | runs | pass | cost-of-pass $ (deck) | cost-of-pass $ (billed rates) | median $ among passes | wall med s |")
        L.append("|---|---|---|---|---|---|---|---|")
        for arm, a in agg["arms"].items():
            for s_, b in a.get("by_size", {}).items():
                L.append("| %s | %s | %d | %d/%d | %s | %s | %s | %s |" % (arm, s_, b["runs_ok"], b["pass"], b["runs_ok"], _f(b["cost_of_pass_usd"]),
                                                                       _f(b.get("cost_of_pass_billed_usd")), _f(b["cost_pass_median"]), _f(b["wall_median_s"])))
    elif kind == "paired":
        L.append("| comparison | tasks | ratio (deck) | 95% CI | ratio (billed rates) | 95% CI | ratio (Claude side only) | 95% CI | pass-rate diff | undefined draws |")
        L.append("|---|---|---|---|---|---|---|---|---|---|")
        pb = agg.get("paired_billed", {}); pc = agg.get("paired_claude_only", {})
        for k, p in agg["paired"].items():
            b = pb.get(k, {}); c = pc.get(k, {})
            L.append("| %s | %d | %s | %s | %s | %s | %s | %s | %s | %d/%d |" % (k, p["n_tasks"], _f(p["point"]), p["ci95"], _f(b.get("point")), b.get("ci95"), _f(c.get("point")), c.get("ci95"), _f(p["pass_rate_diff"]), p["undefined_draws"], p["boot"]))
    elif kind == "judge":
        j = agg.get("judge", {})
        if not j.get("present"):
            L.append("(no judge records)")
        else:
            L.append("| arm | judge | n | mean | " + " | ".join(AXES) + " |")
            L.append("|---|---|---|---|" + "---|" * len(AXES))
            for arm, js in j["by_arm"].items():
                for jn, d in js.items():
                    L.append("| %s | %s | %d | %.2f | %s |" % (arm, jn, d["n"], d["mean"], " | ".join("%.2f" % d[a] for a in AXES)))
            L.append("")
            L.append("anchors: %s; agreement: %s; judge-vs-pass: %s; failed judge calls: %d" % (
                json.dumps(j["anchors"], sort_keys=True), json.dumps(j["agreement"], sort_keys=True),
                json.dumps(j["judge_vs_pass_pointbiserial"], sort_keys=True), j["records_failed"]))
            if j.get("paired_diff"):
                L.append("")
                L.append("paired judge difference (arm − reference; mean of per-task means; task bootstrap 95% CI): " + "; ".join(
                    "%s: %s" % (k, ", ".join("%s %+.2f [%+.2f, %+.2f] (n=%d)" % (jn, v["point"], v["ci95"][0], v["ci95"][1], v["n_tasks"]) for jn, v in d.items()))
                    for k, d in j["paired_diff"].items()))
    else:
        raise ValueError("unknown table kind %r" % kind)
    return "\n".join(L) + "\n"


def render_tables(agg: dict) -> str:
    L: List[str] = ["# %s — tables (generated by bench/harness/analyze.py)" % agg["run_id"], ""]
    for title, kind in (("Per arm (all tasks)", "arms"), ("Per arm × size class", "size"),
                        ("Paired ratios (cost-of-pass, arm ÷ reference; task-level bootstrap)", "paired"),
                        ("Judges (mean 1–5; author and empty-patch anchors included)", "judge")):
        L.append("## " + title)
        L.append("")
        L.append(render_block(agg, kind).rstrip())
        L.append("")
    if agg.get("exclusions"):
        L.append("## Exclusions")
        for e in agg["exclusions"]:
            L.append("- %s: %s" % (e["run_key"], ", ".join(e["violations"])))
        L.append("")
    return "\n".join(L)


def _f(v) -> str:
    if v is None:
        return "—"
    if isinstance(v, float):
        return "%.2f" % v
    return str(v)
