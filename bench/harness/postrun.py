"""Post-run agent: wait for the queue to finish, judge every task, analyze, exit 0.

    bench.py postrun --run-id X --plugin-dir P [--include ...] [--also-ref ...]

Meant to run under launchd next to the lanes (KeepAlive until a clean exit): it polls the
queue, and once no item is pending or running it judges each task (a record left by a
call that died, e.g. in a sleep, is removed and retried; finished records are kept), then
writes the aggregate and `POSTRUN_DONE`. Judging starts only on mains power, like a run.
A STOP file with nothing running makes it exit without judging.
"""
from __future__ import annotations

import glob
import os
import time
from typing import List, Optional

from common import RESULTS_DIR, now_iso, read_json, write_text


def _log(run_id: str, msg: str) -> None:
    line = "%s %s\n" % (now_iso(), msg)
    print(line, end="", flush=True)
    with open(os.path.join(RESULTS_DIR, run_id, "postrun.log"), "a", encoding="utf-8") as fh:
        fh.write(line)


def postrun(run_id: str, plugin_dir: str, include: Optional[str], also_ref: Optional[str], ref: str = "solo-opus",
            judges: Optional[List[str]] = None, poll_s: int = 300, seed: int = 20260914) -> int:
    import analyze as an_mod
    import judge as judge_mod
    from run import wait_for_ac
    from schedule import queue_path
    judges = judges or ["claude", "gemini"]
    stop = os.path.join(RESULTS_DIR, run_id, os.environ.get("BENCH_STOP_FILE", "STOP"))
    while True:
        q = read_json(queue_path(run_id))
        if not any(it["status"] in ("pending", "running") for it in q["items"]):
            break
        if os.path.exists(stop) and not any(it["status"] == "running" for it in q["items"]):
            _log(run_id, "STOP present and nothing running; postrun exits without judging")
            return 0
        time.sleep(poll_s)
    counts = {}
    for it in q["items"]:
        counts[it["status"]] = counts.get(it["status"], 0) + 1
    _log(run_id, "queue finished: %s" % counts)
    for t in q["tasks"]:
        waited = wait_for_ac()
        if waited:
            _log(run_id, "waited %.0f s for mains power before judging %s" % (waited, t))
        for p in glob.glob(os.path.join(RESULTS_DIR, run_id, "judge", t, "*__*.json")):
            if read_json(p).get("status") != "ok":
                os.remove(p)
        recs = judge_mod.judge_task(run_id, t, list(judges), plugin_dir, seed, False)
        _log(run_id, "%s judged: %d ok / %d" % (t, sum(1 for r in recs if r.get("status") == "ok"), len(recs)))
    agg = an_mod.analyze(run_id, ref, 10000, seed, include, also_ref)
    _log(run_id, "analyzed: %d runs, arms %s" % (agg["n_runs"], sorted(agg["arms"])))
    write_text(os.path.join(RESULTS_DIR, run_id, "POSTRUN_DONE"), now_iso() + "\n")
    return 0
