#!/usr/bin/env python3
"""Benchmark CLI. python3 stdlib only.

  bench.py curate mirror <owner/repo>
  bench.py curate make <owner/repo> --prs 7913 --task-id caddy-7913 [--size small|medium|large]
  bench.py curate verify <task-id> [--suite-runs 3]
  bench.py curate lint <task-id>
  bench.py curate prewarm <task-id>
  bench.py run --run-id <id> --task <task-id> --arm <arm> --rep <n> [--plugin-dir <path>] [--lane A] [--keep]
  bench.py rescore --run-id <id> --run-key <key> [--repo-dir <path>]   # re-run scoring on a kept checkout
  bench.py gate "<command>" [--plugin]                                  # ask the policy about one command
  bench.py stop --run-id <id> [--now]
  bench.py versions [--plugin-dir <path>]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "harness"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="bench.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("curate"); cs = c.add_subparsers(dest="ccmd", required=True)
    p = cs.add_parser("mirror"); p.add_argument("repo")
    p = cs.add_parser("make"); p.add_argument("repo"); p.add_argument("--prs", required=True); p.add_argument("--task-id", required=True)
    p.add_argument("--size", choices=["small", "medium", "large"])
    p = cs.add_parser("verify"); p.add_argument("task_id"); p.add_argument("--suite-runs", type=int, default=3)
    p = cs.add_parser("lint"); p.add_argument("task_id")
    p = cs.add_parser("prewarm"); p.add_argument("task_id")
    p = cs.add_parser("vetbase"); p.add_argument("task_id")

    r = sub.add_parser("run")
    r.add_argument("--run-id", required=True); r.add_argument("--task", required=True); r.add_argument("--arm", required=True)
    r.add_argument("--rep", type=int, default=1); r.add_argument("--plugin-dir"); r.add_argument("--lane", default="A")
    r.add_argument("--attempt", type=int, default=1); r.add_argument("--keep", action="store_true")
    r.add_argument("--cap-turns", type=int); r.add_argument("--cap-budget", type=float); r.add_argument("--cap-wall", type=int)

    rs = sub.add_parser("rescore"); rs.add_argument("--run-id", required=True); rs.add_argument("--run-key", required=True)
    rs.add_argument("--repo-dir")

    j = sub.add_parser("judge"); j.add_argument("--run-id", required=True); j.add_argument("--task"); j.add_argument("--judges", default="claude,gemini")
    j.add_argument("--plugin-dir"); j.add_argument("--seed", type=int, default=20260914); j.add_argument("--force", action="store_true")
    an = sub.add_parser("analyze"); an.add_argument("--run-id", required=True); an.add_argument("--ref", default="solo-opus")
    an.add_argument("--boot", type=int, default=10000); an.add_argument("--seed", type=int, default=20260914); an.add_argument("--include"); an.add_argument("--also-ref")
    po = sub.add_parser("postrun"); po.add_argument("--run-id", required=True); po.add_argument("--plugin-dir", required=True)
    po.add_argument("--include"); po.add_argument("--also-ref"); po.add_argument("--ref", default="solo-opus")
    po.add_argument("--judges", default="claude,gemini"); po.add_argument("--poll-s", type=int, default=300)
    b = sub.add_parser("billing"); b.add_argument("--run-id", required=True); b.add_argument("--table"); b.add_argument("--slack-h", type=float, default=3.0)
    ra = sub.add_parser("reaccount"); ra.add_argument("--run-id", required=True)
    qb = sub.add_parser("queue"); qb.add_argument("--run-id", required=True); qb.add_argument("--arms", default="solo-opus,solo-sonnet,hybrid-inst,hybrid-forced")
    qb.add_argument("--reps", type=int, default=3); qb.add_argument("--seed", type=int, default=20260914); qb.add_argument("--tasks")
    sc = sub.add_parser("schedule"); sc.add_argument("--run-id", required=True); sc.add_argument("--lane", required=True)
    sc.add_argument("--plugin-dir", required=True); sc.add_argument("--gap-s", type=float)
    st = sub.add_parser("status"); st.add_argument("--run-id", required=True)
    rq = sub.add_parser("requeue"); rq.add_argument("--run-id", required=True); rq.add_argument("--key", required=True)
    g = sub.add_parser("gate"); g.add_argument("command"); g.add_argument("--plugin", action="store_true")
    s = sub.add_parser("stop"); s.add_argument("--run-id", required=True); s.add_argument("--now", action="store_true")
    v = sub.add_parser("versions"); v.add_argument("--plugin-dir")

    a = ap.parse_args(argv)
    if a.cmd == "curate":
        import curate
        if a.ccmd == "mirror":
            print(curate.ensure_mirror(a.repo)); return 0
        if a.ccmd == "make":
            print(curate.make(a.repo, a.prs, a.task_id, a.size)); return 0
        if a.ccmd == "verify":
            rep = curate.verify(a.task_id, a.suite_runs); print(json.dumps(rep, indent=2)); return 0 if rep["ok"] else 1
        if a.ccmd == "lint":
            rep = curate.lint_prompt(a.task_id); print(json.dumps(rep, indent=2)); return 0 if rep["ok"] else 1
        if a.ccmd == "prewarm":
            print(json.dumps(curate.prewarm(a.task_id), indent=2)); return 0
        if a.ccmd == "vetbase":
            print(json.dumps(curate.vetbase(a.task_id), indent=2)); return 0
    if a.cmd == "run":
        import run as run_mod
        rec = run_mod.run_once(a.task, a.arm, a.rep, a.run_id, a.plugin_dir, a.lane, a.attempt, a.keep,
                               {"max_turns": a.cap_turns, "max_budget_usd": a.cap_budget, "wall_s": a.cap_wall})
        print(json.dumps({k: rec[k] for k in ("run_key", "outcome", "cost", "violations")}, indent=2))
        return 0
    if a.cmd == "rescore":
        import run as run_mod
        import score
        from common import GOBUILD_DIR, GOMOD_DIR, RESULTS_DIR, Prices, load_task, read_json
        run_dir = os.path.join(RESULTS_DIR, a.run_id, "runs", a.run_key)
        meta = read_json(os.path.join(run_dir, "raw", "meta.json"))
        task, task_dir = load_task(meta["task_id"])
        repo_dir = a.repo_dir or meta["repo_dir"]
        rec = score.score_run(run_dir, repo_dir, task, task_dir, run_mod.repo_config(task_dir), meta["arm"], Prices(),
                              GOMOD_DIR, GOBUILD_DIR, meta)
        print(json.dumps({k: rec[k] for k in ("run_key", "outcome", "cost", "violations")}, indent=2))
        return 0
    if a.cmd == "judge":
        import judge as judge_mod
        from common import RESULTS_DIR
        tasks = [a.task] if a.task else sorted({os.path.basename(p).split("__")[0] for p in glob.glob(os.path.join(RESULTS_DIR, a.run_id, "runs", "*"))})
        for t in tasks:
            recs = judge_mod.judge_task(a.run_id, t, a.judges.split(","), a.plugin_dir, a.seed, a.force)
            print(t, "judged:", sum(1 for r in recs if r.get("status") == "ok"), "ok /", len(recs))
        return 0
    if a.cmd == "postrun":
        import postrun as pr_mod
        return pr_mod.postrun(a.run_id, a.plugin_dir, a.include, a.also_ref, a.ref, a.judges.split(","), a.poll_s)
    if a.cmd == "analyze":
        import analyze as an_mod
        agg = an_mod.analyze(a.run_id, a.ref, a.boot, a.seed, a.include, a.also_ref)
        print(open(os.path.join(HERE, "results", a.run_id, "tables.md")).read())
        return 0
    if a.cmd == "billing":
        import billing
        out = billing.reconcile(a.run_id, a.table or billing.DEFAULT_TABLE, a.slack_h)
        print(json.dumps({k: v for k, v in out.items() if k != "families"}, indent=2))
        for fam, f in out["families"].items():
            print("%-16s computed $%-9.4f billed %-10s gap %s" % (fam, f["computed_usd"], ("$%.4f" % f["billed_usd"]) if f["billed_usd"] is not None else "-", ("%+.1f%%" % f["gap_pct"]) if f["gap_pct"] is not None else "-"))
        return 0
    if a.cmd == "queue":
        import schedule
        q = schedule.build_queue(a.run_id, a.arms.split(","), a.reps, a.seed, a.tasks.split(",") if a.tasks else None)
        print(json.dumps({"run_id": q["run_id"], "items": len(q["items"]), "tasks": q["tasks"], "arms": q["arms"], "reps": q["reps"]}, indent=2))
        return 0
    if a.cmd == "schedule":
        import schedule
        schedule.lane(a.run_id, a.lane, a.plugin_dir, a.gap_s)
        return 0
    if a.cmd == "status":
        import schedule
        print(json.dumps(schedule.status(a.run_id), indent=2))
        return 0
    if a.cmd == "requeue":
        import schedule
        it = schedule.requeue(a.run_id, a.key); print(json.dumps({"key": a.key, "status": it["status"], "attempts": it["attempts"]}))
        return 0
    if a.cmd == "reaccount":
        import score
        from common import RESULTS_DIR, Prices, load_task
        pr = Prices()
        for rj in sorted(glob.glob(os.path.join(RESULTS_DIR, a.run_id, "runs", "*", "run.json"))):
            rd = os.path.dirname(rj); rec = json.load(open(rj)); task, _ = load_task(rec["task_id"])
            new = score.reaccount(rd, task, rec["arm"], pr)
            print(json.dumps({"run_key": new["run_key"], "pass": new["outcome"]["pass"], "tree_pass": new["outcome"]["tree_pass"], "capped": new["claude"]["capped"], "cost": new["cost"], "violations": new["violations"]}))
        return 0
    if a.cmd == "gate":
        import gates
        d = gates.decide(a.command, plugin=a.plugin)
        print(json.dumps({"allow": d.allow, "reason": d.reason, "heads": d.heads}))
        return 0 if d.allow else 2
    if a.cmd == "stop":
        from common import RESULTS_DIR
        path = os.path.join(RESULTS_DIR, a.run_id, "STOP-NOW" if a.now else "STOP")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").close(); print(path); return 0
    if a.cmd == "versions":
        import run as run_mod
        print(json.dumps(run_mod.tool_versions(a.plugin_dir), indent=2)); return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
