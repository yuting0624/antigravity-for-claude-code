"""Two-lane scheduler for the full run: a resumable queue with the cold-start rule,
infrastructure retries and a kill switch.

    bench.py schedule --run-id full --lane A --plugin-dir ~/.cache/agy-bench/plugin
    bench.py schedule --run-id full --lane B --plugin-dir ~/.cache/agy-bench/plugin
    bench.py status   --run-id full

Queue (results/<run-id>/queue.json) is built once from arms.json × the verified tasks ×
reps, ordered by (rep, seeded task order, rotated arm order) so consecutive items differ
in task and arm. A lane may start an item only if ≥ cold_gap_s have passed since the last
run of the same arm ended on either lane, and since the last run of the same task ended;
otherwise it takes the first eligible item, or waits. `first_turn_cache_read` in each
run.json is the ground truth for whether the rule held.

Outcome classes: a run whose failure is infrastructure (Vertex 429/529 or a model error
before any tool call, agy quota/auth/model-unavailable on every delegation, a harness
exception) is retried at most twice; the failed attempt is kept under attempts/<n>/ and
counted. Everything else is final. A STOP file ends the lane after the current run;
STOP-NOW is honoured between runs too (the running process is not killed here).
"""
from __future__ import annotations

import fcntl
import json
import os
import random
import shutil
import time
import traceback
from typing import Dict, List, Optional

from common import RESULTS_DIR, TASKS_DIR, load_arms, now_iso, read_json, write_json

INFRA_SIGNALS = {"QUOTA_EXHAUSTED", "AUTH_REQUIRED", "MODEL_UNAVAILABLE", "AGY_MISSING"}
MAX_ATTEMPTS = 3          # infrastructure failures: an item is retried at most twice
MAX_SUSPENDED = 6         # machine-sleep interruptions are the operator's, not the arm's: a separate, larger budget


# ------------------------------------------------------------------ queue ----

def verified_tasks() -> List[dict]:
    out = []
    for repo in sorted(os.listdir(TASKS_DIR)):
        rd = os.path.join(TASKS_DIR, repo)
        if not os.path.isdir(rd):
            continue
        for tid in sorted(os.listdir(rd)):
            tj = os.path.join(rd, tid, "task.json")
            if os.path.isfile(tj):
                t = read_json(tj)
                if t.get("verify", {}).get("status") == "ok" and os.path.isfile(os.path.join(rd, tid, "prompt.md")):
                    out.append(t)
    return out


def build_queue(run_id: str, arms: List[str], reps: int, seed: int, tasks: Optional[List[str]] = None) -> dict:
    ts = verified_tasks()
    if tasks:
        ts = [t for t in ts if t["task_id"] in tasks]
    ids = [t["task_id"] for t in ts]
    size = {t["task_id"]: t["size_class"] for t in ts}
    rng = random.Random(seed)
    items: List[dict] = []
    k = 0  # runs across reps so the arm rotation never restarts on a rep boundary
    for rep in range(1, reps + 1):
        order = ids[:]
        rng.shuffle(order)
        for tid in order:
            r = 0 if len(arms) == 2 else k % len(arms)  # two arms: rotating would put the same arm back to back
            rot = arms[r:] + arms[:r]
            k += 1
            for arm in rot:
                items.append({"task_id": tid, "arm": arm, "rep": rep, "size_class": size[tid], "status": "pending",
                              "attempts": 0, "lane": None, "started_at": None, "ended_at": None, "history": []})
    q = {"run_id": run_id, "seed": seed, "arms": arms, "reps": reps, "tasks": ids, "created_at": now_iso(), "items": items}
    write_json(queue_path(run_id), q)
    return q


def queue_path(run_id: str) -> str:
    return os.path.join(RESULTS_DIR, run_id, "queue.json")


class Locked:
    def __init__(self, run_id: str):
        self.path = os.path.join(RESULTS_DIR, run_id, "queue.lock")
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fh = None

    def __enter__(self):
        self.fh = open(self.path, "a+")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


def _key(it: dict) -> str:
    return "%s__%s__r%d" % (it["task_id"], it["arm"], it["rep"])


def eligible(items: List[dict], now: float, gap_s: float, same_arm_concurrency: bool = False) -> Optional[int]:
    """Index of the first pending item whose arm and task both ended ≥ gap_s ago (or never ran).

    Two runs of the same arm never overlap unless `same_arm_concurrency` is set. Claude
    Code's system prompt embeds the working directory, and every item has its own checkout,
    so concurrent same-arm runs on different tasks do not share a prompt-cache prefix
    (measured: the only warm starts in the main run were reruns in a reused checkout);
    single-arm follow-ups set the flag in queue.json so two lanes can work."""
    last_arm: Dict[str, float] = {}
    last_task: Dict[str, float] = {}
    running_arms = set()
    running_tasks = set()
    for it in items:
        if it["status"] == "running":
            running_arms.add(it["arm"]); running_tasks.add(it["task_id"])
        for h in it.get("history", []):
            e = h.get("ended_ts")
            if e:
                last_arm[it["arm"]] = max(last_arm.get(it["arm"], 0), e)
                last_task[it["task_id"]] = max(last_task.get(it["task_id"], 0), e)
    for i, it in enumerate(items):
        if it["status"] != "pending":
            continue
        if (it["arm"] in running_arms and not same_arm_concurrency) or it["task_id"] in running_tasks:
            continue
        if now - last_arm.get(it["arm"], 0) < gap_s:
            continue
        if now - last_task.get(it["task_id"], 0) < gap_s:
            continue
        return i
    return None


def classify(rec: Optional[dict], error: Optional[str]) -> str:
    """'infra' or 'final' for a finished attempt."""
    if error:
        return "infra"
    if rec.get("env_failure"):
        return "infra"  # e.g. plugin_bin_missing: the harness, not the arm
    c = rec.get("claude", {})
    # Claude Code reports subtype "success" with is_error=true when the final message is an
    # API error (measured: "API Error: getaddrinfo ENOTFOUND oauth2.googleapis.com" right
    # after a wake, 0 files changed). That is the network, not the arm.
    errs_txt = " ".join(c.get("errors") or []).lower()
    api_death = bool(c.get("is_error")) and c.get("subtype") not in ("error_max_turns", "error_max_budget_usd", "killed_wall") and (
        str(c.get("result_head") or "").startswith("API Error")
        or any(k in errs_txt for k in ("enotfound", "econnreset", "etimedout", "429", "529", "overloaded", "rate limit")))
    if api_death:
        return "suspended" if (rec.get("suspended_s") or 0) > 30 else "infra"
    if (rec.get("suspended_s") or 0) > 30:
        # The machine slept during the run. Claude Code retries the interrupted API call on
        # wake and the wall cap counts active time, so a run that then completed normally is
        # kept (flagged `slept`, reported with a sensitivity table); only a run that died of
        # it — killed, or an execution error — is rerun as 'suspended'.
        if c.get("subtype") in ("killed_wall", "error_during_execution") or not c.get("total_cost_usd"):
            return "suspended"
        # The executor's connection does not survive a sleep either (measured 2026-09-18:
        # cli-attach hand-off-review r1 slept 67 min; both delegations came back "network
        # issue connecting to the server" / TIMEOUT after 126 and 22 min, the run failed
        # with nothing to show). A delegating run in which no delegation succeeded and
        # that did not pass is the sleep's death, not the arm's result.
        a_ = rec.get("agy") or {}
        if (a_.get("delegations") or 0) > 0 and not a_.get("succeeded") and not (rec.get("outcome") or {}).get("pass"):
            return "suspended"
    
    tool_calls = sum((c.get("transcript") or {}).get("tool_calls", {}).values()) if c.get("transcript") else 0
    errs = " ".join(c.get("errors") or []).lower()
    if c.get("subtype") == "error_during_execution" and (tool_calls == 0 or any(k in errs for k in ("429", "529", "overloaded", "rate limit"))):
        return "infra"
    a = rec.get("agy", {})
    sig = a.get("signals") or {}
    if a.get("delegations") and a.get("usage_lines", 0) == 0 and any(s in INFRA_SIGNALS for s in sig):
        return "infra"
    if not c.get("transcript", {}).get("present") and not c.get("total_cost_usd"):
        return "infra"
    return "final"


def lane(run_id: str, lane_id: str, plugin_dir: str, gap_s: Optional[float] = None, poll_s: int = 30) -> None:
    arms = load_arms()
    gap = float(gap_s if gap_s is not None else arms.get("cold_gap_s", 300))
    stop_name = os.environ.get("BENCH_STOP_FILE", "STOP")  # lets a new generation of lanes ignore the old lanes' stop
    stop = os.path.join(RESULTS_DIR, run_id, stop_name)
    stop_now = os.path.join(RESULTS_DIR, run_id, stop_name + "-NOW")
    log = open(os.path.join(RESULTS_DIR, run_id, "lane-%s.log" % lane_id), "a")

    def say(msg: str):
        log.write("%s %s\n" % (now_iso(), msg)); log.flush(); print(msg, flush=True)

    say("lane %s start (gap %.0fs)" % (lane_id, gap))
    # A lane that died mid-run (machine sleep, tool timeout, kill) leaves its item "running";
    # on restart the same lane id reclaims it: the partial attempt is kept and counted as
    # interrupted, the item goes back to pending.
    with Locked(run_id):
        q = read_json(queue_path(run_id))
        for it in q["items"]:
            if it["status"] == "running" and it.get("lane") == lane_id:
                key = _key(it)
                rd = os.path.join(RESULTS_DIR, run_id, "runs", key)
                if os.path.isdir(rd):
                    dst = os.path.join(rd + "__attempts", str(it["attempts"]))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.move(rd, dst)
                it["history"].append({"attempt": it["attempts"], "lane": lane_id, "started_ts": None, "ended_ts": time.time(),
                                      "class": "interrupted", "error": "lane restarted while the item was running", "pass": None,
                                      "total_usd": None, "subtype": None})
                it["status"] = "pending"
                say("lane %s reclaimed interrupted item %s (attempt %d)" % (lane_id, key, it["attempts"]))
        write_json(queue_path(run_id), q)
    on_batt_logged = False
    while True:
        if os.path.exists(stop) or os.path.exists(stop_now):
            say("STOP present; lane %s exits" % lane_id); return
        # no new item on battery power: the study's run deaths all followed sleeps entered
        # on battery (lid closed); running items are left alone
        import run as run_mod
        if not run_mod.on_ac_power():
            if not on_batt_logged:
                say("lane %s: on battery power; not starting new items until mains power returns" % lane_id); on_batt_logged = True
            time.sleep(60); continue
        if on_batt_logged:
            say("lane %s: mains power back" % lane_id); on_batt_logged = False
        with Locked(run_id):
            q = read_json(queue_path(run_id))
            items = q["items"]
            if all(it["status"] in ("done", "gave_up") for it in items):
                say("queue complete; lane %s exits" % lane_id); return
            idx = eligible(items, time.time(), gap, bool(q.get("allow_same_arm_concurrency")))
            if idx is not None:
                it = items[idx]
                it["status"] = "running"; it["lane"] = lane_id; it["attempts"] += 1
                it["started_at"] = now_iso()
                write_json(queue_path(run_id), q)
        if idx is None:
            time.sleep(poll_s); continue
        key = _key(it); attempt = it["attempts"]
        run_dir = os.path.join(RESULTS_DIR, run_id, "runs", key)
        if attempt > 1 and os.path.isdir(run_dir):
            dst = os.path.join(run_dir + "__attempts", str(attempt - 1))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(run_dir, dst)
        say("lane %s -> %s (attempt %d)" % (lane_id, key, attempt))
        t0 = time.time(); rec = None; err = None
        # each item runs in a fresh interpreter so a harness fix committed mid-run applies at
        # the next item without restarting the lane (versions and hashes stay per-run records)
        import subprocess, sys
        bench_py = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bench.py")
        cmd = [sys.executable, bench_py, "run", "--run-id", run_id, "--task", it["task_id"], "--arm", it["arm"],
               "--rep", str(it["rep"]), "--plugin-dir", plugin_dir, "--lane", lane_id]
        try:
            pr = subprocess.run(cmd, capture_output=True, text=True, timeout=6 * 3600)
            rj = os.path.join(run_dir, "run.json")
            if os.path.isfile(rj):
                rec = read_json(rj)
            else:
                err = "no run.json (rc %s): %s" % (pr.returncode, (pr.stderr or pr.stdout)[-1500:])
        except subprocess.TimeoutExpired:
            err = "run subprocess exceeded 6h"
        except Exception:  # noqa: BLE001
            err = traceback.format_exc()[-2000:]
        cls = (rec or {}).get("scheduler_class") or classify(rec, err)
        with Locked(run_id):
            q = read_json(queue_path(run_id))
            it2 = next(x for x in q["items"] if _key(x) == key)
            it2["history"].append({"attempt": attempt, "lane": lane_id, "started_ts": t0, "ended_ts": time.time(),
                                   "class": cls, "error": (err or "")[-500:] or None,
                                   "pass": (rec or {}).get("outcome", {}).get("pass"),
                                   "total_usd": (rec or {}).get("cost", {}).get("total_usd"),
                                   "subtype": (rec or {}).get("claude", {}).get("subtype")})
            it2["ended_at"] = now_iso()
            n_infra = sum(1 for h in it2["history"] if h.get("class") == "infra")
            n_susp = sum(1 for h in it2["history"] if h.get("class") in ("suspended", "interrupted"))
            if cls == "suspended" and n_susp < MAX_SUSPENDED:
                it2["status"] = "pending"
                say("lane %s: %s interrupted by machine sleep (%.0fs asleep); will retry" % (lane_id, key, (rec or {}).get("suspended_s") or 0))
            elif cls == "infra" and n_infra < MAX_ATTEMPTS:
                it2["status"] = "pending"
                say("lane %s: %s infra failure (%s); will retry" % (lane_id, key, (err or (rec or {}).get("claude", {}).get("subtype"))))
            elif cls in ("infra", "suspended"):
                it2["status"] = "gave_up"
                say("lane %s: %s gave up after %d attempts (%s)" % (lane_id, key, attempt, cls))
            else:
                it2["status"] = "done"
                say("lane %s: %s done pass=%s $%s in %.0fs" % (lane_id, key, it2["history"][-1]["pass"], it2["history"][-1]["total_usd"], time.time() - t0))
            write_json(queue_path(run_id), q)
        if cls == "infra":
            time.sleep(300)  # back off before anyone retries
        elif cls == "suspended":
            time.sleep(60)   # the machine just woke; let the network settle


def status(run_id: str) -> dict:
    q = read_json(queue_path(run_id))
    items = q["items"]
    by = {}
    for it in items:
        by[it["status"]] = by.get(it["status"], 0) + 1
    spent = sum((h.get("total_usd") or 0) for it in items for h in it.get("history", []))
    done = [it for it in items if it["status"] == "done"]
    passes = sum(1 for it in done if it["history"] and it["history"][-1].get("pass"))
    per_arm = {}
    for it in done:
        a = per_arm.setdefault(it["arm"], {"done": 0, "pass": 0, "usd": 0.0})
        a["done"] += 1; a["pass"] += 1 if it["history"][-1].get("pass") else 0; a["usd"] += it["history"][-1].get("total_usd") or 0
    running = [(_key(it), it["lane"], it["started_at"]) for it in items if it["status"] == "running"]
    return {"run_id": run_id, "counts": by, "total": len(items), "spent_usd": round(spent, 2), "passes": passes,
            "per_arm": per_arm, "running": running, "retries": sum(max(0, it["attempts"] - 1) for it in items)}


def requeue(run_id: str, key: str) -> dict:
    """Put a gave_up (or done) item back to pending by hand; its history is kept."""
    with Locked(run_id):
        q = read_json(queue_path(run_id))
        it = next(x for x in q["items"] if _key(x) == key)
        it["status"] = "pending"
        it["history"].append({"attempt": it["attempts"], "lane": None, "started_ts": None, "ended_ts": time.time(),
                              "class": "requeued", "error": "requeued by operator", "pass": None, "total_usd": None, "subtype": None})
        write_json(queue_path(run_id), q)
    return it
